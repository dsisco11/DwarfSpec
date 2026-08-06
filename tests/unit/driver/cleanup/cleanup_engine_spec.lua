-- Unit contracts for cleanup transaction planning and execution.

local CleanupPlanner = require('dwarfspec.driver.cleanup.cleanup_planner')
local CleanupRegistry = require('dwarfspec.driver.cleanup.cleanup_registry')
local CleanupTransaction = require(
    'dwarfspec.driver.cleanup.cleanup_transaction')
local ResourceDependencyIndex = require(
    'dwarfspec.driver.command.resource_dependency_index')
local CleanupLifetime = require('dwarfspec.protocol.enums.cleanup_lifetimes')
local OwnerScope = require('dwarfspec.protocol.enums.execution_owner_scopes')

---@param callback fun()
---@param expected string
local function assert_error(callback, expected)
    local succeeded, message = pcall(callback)
    assert.is_false(succeeded)
    assert.is_truthy(tostring(message):find(expected, 1, true))
end

---@param transaction_id string
---@param ordinal integer
---@return table
local function transaction_stub(transaction_id, ordinal)
    return {transaction_id=function() return transaction_id end,
        registration_ordinal=function() return ordinal end}
end

describe('CleanupPlanner', function()
    it('orders dependents before prerequisites and independent work by LIFO',
            function()
        local dependencies = {parent={'child'}, child={}, independent={}}
        local planner = CleanupPlanner.new(function(transaction_id)
            return dependencies[transaction_id] or {}
        end)
        local ordered = planner:order({transaction_stub('parent', 1),
            transaction_stub('child', 2), transaction_stub('independent', 3)})
        assert.same({'independent', 'child', 'parent'}, {
            ordered[1]:transaction_id(), ordered[2]:transaction_id(),
            ordered[3]:transaction_id()})
    end)

    it('rejects a graph-local prospective transaction cycle before publication',
            function()
        local dependencies = {parent={'child'}, child={'parent'}}
        local planner = CleanupPlanner.new(function(transaction_id)
            return dependencies[transaction_id] or {}
        end)
        assert_error(function()
            planner:validate_prospective({'parent', 'child'}, 'next', {})
        end, 'cycle')
    end)

    it('projects claim edges onto their owning transactions and collapses them',
            function()
        local index = ResourceDependencyIndex.new('run-1')
        local owner = {owner_scope=OwnerScope.TEST_ATTEMPT,
            service_run_id='run-1', suite_execution_id='suite-1',
            test_attempt_id='test-1'}
        local parent_plan = index:validate_plan(owner, 'parent-invocation',
            CleanupLifetime.OWNER, {{claim_key='first', resource_kind='item',
                resource_identity='first', exclusive=true},
            {claim_key='second', resource_kind='item', resource_identity='second',
                exclusive=true}})
        local references = index:activate(parent_plan, 'parent',
            {{claim_key='first'}, {claim_key='second'}})
        local child_plan = index:validate_plan(owner, 'child-invocation',
            CleanupLifetime.OWNER, {{claim_key='child', resource_kind='item',
                resource_identity='child', exclusive=true,
                depends_on_references={references[1], references[2]}}})
        index:activate(child_plan, 'child', {{claim_key='child'}})
        assert.same({'child'}, index:dependent_transaction_ids('parent'))
        local planner = CleanupPlanner.new(function(transaction_id)
            return index:dependent_transaction_ids(transaction_id)
        end)
        local ordered = planner:order({transaction_stub('parent', 1),
            transaction_stub('child', 2)})
        assert.same({'child', 'parent'}, {ordered[1]:transaction_id(),
            ordered[2]:transaction_id()})
    end)
end)

describe('CleanupTransaction', function()
    it('freezes the receipt, removes pending work before restore, and is idempotent',
            function()
        local pending, released = true, false
        local receipt = {item_id='item-1'}
        local transaction
        transaction = CleanupTransaction.new({transaction_id='cleanup-1',
            registration_ordinal=1, label='destroy item', receipt=receipt,
            now_ms=function() return 0 end, remove_pending=function() pending = false end,
            release_verified=function() released = true end,
            restore=function(transaction_context, frozen_receipt)
                assert.is_false(pending)
                assert.are.equal('running', transaction:state())
                assert.are.equal('item-1', frozen_receipt.item_id)
                assert_error(function() frozen_receipt.item_id = 'other' end,
                    'immutable')
            end, verify=function() return true end})
        receipt.item_id = 'changed'
        assert.is_true(transaction:execute('manual'))
        assert.is_true(released)
        assert.are.equal('complete', transaction:state())
        assert.is_false(transaction:execute('manual'))
    end)

    it('keeps dependency-blocked manual work pending without running callbacks',
            function()
        local invoked = false
        local transaction = CleanupTransaction.new({transaction_id='parent',
            registration_ordinal=1, label='parent cleanup', receipt={},
            now_ms=function() return 0 end, remove_pending=function() end,
            release_verified=function() end, blocking_dependents=function()
                return {'child'}
            end, restore=function() invoked = true end, verify=function() return true end})
        assert_error(function() transaction:execute('manual') end, 'dependency_blocked')
        assert.is_true(transaction:isPending())
        assert.is_false(invoked)
    end)

    it('retries pending verification under the fresh cleanup deadline', function()
        local now, observations = 0, 0
        local transaction = CleanupTransaction.new({transaction_id='cleanup-1',
            registration_ordinal=1, label='eventual cleanup', receipt={},
            now_ms=function() return now end, cleanup_timeout_ms=3,
            remove_pending=function() end, release_verified=function() end,
            wait=function() now = now + 1 end, restore=function() end,
            verify=function()
                observations = observations + 1
                return observations == 3
            end})
        assert.is_true(transaction:execute())
        assert.are.equal(3, observations)
    end)

    it('retains the latest thrown verification observation on deadline expiry',
            function()
        local now, observations = 0, 0
        local transaction = CleanupTransaction.new({transaction_id='cleanup-1',
            registration_ordinal=1, label='failing verification', receipt={},
            now_ms=function() return now end, cleanup_timeout_ms=2,
            remove_pending=function() end, release_verified=function() end,
            wait=function() now = now + 1 end, restore=function() end,
            verify=function()
                observations = observations + 1
                error('latest verification failure ' .. observations)
            end})
        assert_error(function() transaction:execute() end,
            'latest verification failure 2')
        assert.are.equal('failed', transaction:state())
        assert.is_truthy(transaction:evidence().failures[1]:find(
            'latest verification failure 2', 1, true))
    end)

    it('rejects metatable-bearing receipts before copying them', function()
        local protected = setmetatable({item_id='item-1'}, {
            __metatable=false,
            __pairs=function() return next, {}, nil end,
        })
        for _, receipt in ipairs({protected, {nested=protected}}) do
            assert_error(function()
                CleanupTransaction.new({transaction_id='cleanup-1',
                    registration_ordinal=1, label='invalid receipt', receipt=receipt,
                    now_ms=function() return 0 end, remove_pending=function() end,
                    release_verified=function() end, restore=function() end,
                    verify=function() return true end})
            end, 'metatables')
        end
    end)

    it('creates a fresh cleanup cancellation scope when it is expended', function()
        local scopes = 0
        local transaction = CleanupTransaction.new({transaction_id='cleanup-1',
            registration_ordinal=1, label='fresh cancellation', receipt={},
            now_ms=function() return 0 end, remove_pending=function() end,
            release_verified=function() end, new_cancellation=function()
                scopes = scopes + 1
                return function() return false, nil end
            end, restore=function(context)
                assert.is_false(context:cancellation())
            end, verify=function() return true end})
        assert.is_true(transaction:execute())
        assert.are.equal(1, scopes)
    end)

    it('records failed cleanup after restore errors while still attempting verification',
            function()
        local verified, retained = false, false
        local transaction = CleanupTransaction.new({transaction_id='cleanup-1',
            registration_ordinal=1, label='partial cleanup', receipt={},
            now_ms=function() return 0 end, remove_pending=function() end,
            release_verified=function() end, retain_unresolved=function() retained = true end,
            restore=function() error('restore failure') end,
            verify=function() verified = true return true end})
        assert_error(function() transaction:execute() end, 'restore')
        assert.is_true(verified)
        assert.is_true(retained)
        assert.are.equal('failed', transaction:state())
    end)

    it('terminalizes cancellation after restore without invoking verification', function()
        local verified = false
        local transaction = CleanupTransaction.new({transaction_id='cleanup-1',
            registration_ordinal=1, label='cancelled cleanup', receipt={},
            now_ms=function() return 0 end, remove_pending=function() end,
            release_verified=function() end, new_cancellation=function()
                return function() return true, 'emergency stop' end
            end, restore=function() end, verify=function()
                verified = true
                return true
            end})
        assert_error(function() transaction:execute() end, 'cancelled')
        assert.is_false(verified)
        assert.are.equal('failed', transaction:state())
    end)

    it('restricts restore from invoking public commands', function()
        local transaction = CleanupTransaction.new({transaction_id='cleanup-1',
            registration_ordinal=1, label='restricted cleanup', receipt={},
            now_ms=function() return 0 end, remove_pending=function() end,
            release_verified=function() end, restore=function(context)
                context:invoke_readonly('query', 'status')
            end, verify=function() return true end})
        assert_error(function() transaction:execute() end, 'restore cannot invoke')
    end)

    it('rejects mutating commands from cleanup verification', function()
        local transaction = CleanupTransaction.new({transaction_id='cleanup-1',
            registration_ordinal=1, label='restricted verification', receipt={},
            now_ms=function() return 0 end, remove_pending=function() end,
            release_verified=function() end, restore=function() end,
            verify=function(context)
                context:invoke_readonly('action', 'mutate')
            end})
        assert_error(function() transaction:execute() end, 'only read-only')
    end)

    it('supports internal abandoned and unconfirmed terminal dispositions', function()
        local removed, retained, released = false, false, false
        local transaction = CleanupTransaction.new({transaction_id='cleanup-1',
            registration_ordinal=1, label='terminal cleanup', receipt={},
            now_ms=function() return 0 end, remove_pending=function() removed = true end,
            release_verified=function() released = true end,
            retain_unresolved=function() retained = true end,
            restore=function() end, verify=function() return true end})
        CleanupTransaction._mark_unconfirmed(transaction, {reason='host lost'})
        assert.is_true(removed)
        assert.is_true(retained)
        assert.are.equal('unconfirmed', transaction:state())
        local abandoned = CleanupTransaction.new({transaction_id='cleanup-2',
            registration_ordinal=2, label='absent cleanup', receipt={},
            now_ms=function() return 0 end, remove_pending=function() end,
            release_verified=function() released = true end,
            restore=function() end, verify=function() return true end})
        CleanupTransaction._abandon_verified(abandoned, {identity='item-2'})
        assert.is_true(released)
        assert.are.equal('abandoned', abandoned:state())
    end)
end)

describe('CleanupRegistry', function()
    it('continues later eligible transactions after an earlier cleanup failure',
            function()
        local registry = CleanupRegistry.new(function() return {} end)
        local completed = false
        local function add(transaction_id, ordinal, restore)
            local transaction = CleanupTransaction.new({transaction_id=transaction_id,
                registration_ordinal=ordinal, label=transaction_id, receipt={},
                now_ms=function() return 0 end,
                remove_pending=function(item) registry:remove_pending(item) end,
                release_verified=function() end, restore=restore,
                verify=function() completed = true return true end})
            registry:add(transaction)
        end
        add('first', 1, function() error('first failure') end)
        add('second', 2, function() end)
        local succeeded, failures = registry:execute_all('teardown')
        assert.is_false(succeeded)
        assert.are.equal(1, #failures)
        assert.is_true(completed)
    end)

    it('terminalizes an unsafe prerequisite after dependent cleanup failure',
            function()
        local dependencies = {parent={'child'}, child={}}
        local registry = CleanupRegistry.new(function(transaction_id)
            return dependencies[transaction_id] or {}
        end)
        local parent_restore = false
        local function add(transaction_id, ordinal, restore)
            local transaction = CleanupTransaction.new({transaction_id=transaction_id,
                registration_ordinal=ordinal, label=transaction_id, receipt={},
                now_ms=function() return 0 end,
                remove_pending=function(item) registry:remove_pending(item) end,
                release_verified=function() end, restore=restore,
                verify=function() return true end,
                blocking_dependents=function(id) return registry:blocking_dependents(id) end})
            registry:add(transaction)
            return transaction
        end
        local parent = add('parent', 1, function() parent_restore = true end)
        add('child', 2, function() error('child failure') end)
        local succeeded = registry:execute_all('teardown')
        assert.is_false(succeeded)
        assert.is_false(parent_restore)
        assert.are.equal('failed', parent:state())
        assert.are.equal('dependency_blocked', parent:evidence().reason)
    end)
end)
