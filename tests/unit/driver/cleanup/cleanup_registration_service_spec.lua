-- Unit contracts for atomic cleanup registration and lifecycle journal ownership.

local CleanupRegistrationService = require(
    'dwarfspec.driver.cleanup.cleanup_registration_service')
local CleanupTransaction = require(
    'dwarfspec.driver.cleanup.cleanup_transaction')
local ResourceDependencyIndex = require(
    'dwarfspec.driver.command.resource_dependency_index')
local CleanupLifetime = require('dwarfspec.protocol.enums.cleanup_lifetimes')
local OwnerScope = require('dwarfspec.protocol.enums.execution_owner_scopes')
local Outcomes = require('dwarfspec.driver.command.outcomes')

---@param callback fun()
---@param expected string
local function assert_error(callback, expected)
    local succeeded, message = pcall(callback)
    assert.is_false(succeeded)
    assert.is_truthy(tostring(message):find(expected, 1, true))
end

---@return table
local function owner()
    return {owner_scope=OwnerScope.TEST_ATTEMPT, service_run_id='run-1',
        suite_execution_id='suite-1', test_attempt_id='test-1'}
end

---@param index dwarfspec.ResourceDependencyIndex
---@return dwarfspec.CleanupRegistrationService
local function service(index)
    return CleanupRegistrationService.new({service_run_id='run-1',
        resource_index=index, now_ms=function() return 10 end})
end

---@param index dwarfspec.ResourceDependencyIndex
---@return table
local function plan(index)
    return index:validate_plan(owner(), 'command-1', CleanupLifetime.COMMAND,
        {{claim_key='item', resource_kind='item', resource_identity='item-1',
            exclusive=true}})
end

---@param cleanup_service dwarfspec.CleanupRegistrationService
---@param resource_index dwarfspec.ResourceDependencyIndex
---@param mutation_lease? dwarfspec.CleanupMutationLease
---@return dwarfspec.CleanupTransaction
local function register(cleanup_service, resource_index, mutation_lease)
    local lease = mutation_lease or cleanup_service:begin_mutation('command-1')
    local transaction = cleanup_service:register({owner=owner(), command_invocation_id='command-1',
        label='destroy item', lifetime=CleanupLifetime.COMMAND, receipt={item_id='item-1'},
        plan=plan(resource_index), bindings={{claim_key='item'}}, mutation_lease=lease,
        restore=function() end,
        verify=function() return true end})
    if mutation_lease == nil then lease:release() end
    return transaction
end

---@return table
local function absence_proof(resource_identity)
    return Outcomes.effect_absent('claimed resource is absent', {
        absent_resources={{resource_kind='item', resource_identity=resource_identity}},
    })
end

describe('CleanupRegistrationService', function()
    it('creates one pending transaction and all active claims before publishing registration',
            function()
        local index = ResourceDependencyIndex.new('run-1', function() return 'complete' end)
        local cleanup_service = service(index)
        local transaction = register(cleanup_service, index)
        assert.is_true(transaction:isPending())
        local references = transaction:claimReferences()
        assert.are.equal(1, #references)
        assert.are.equal(transaction:transaction_id(), references[1].transaction_id)
        local journal = cleanup_service:journal()
        assert.are.equal(1, #journal)
        assert.are.equal('cleanup.transaction_registered', journal[1].event)
        assert.are.equal(transaction:transaction_id(), journal[1].transaction_id)
        assert.are.equal('test_attempt', journal[1].owner.owner_scope)
    end)

    it('uses run-unique identifiers and owner-local registration ordinals', function()
        local index = ResourceDependencyIndex.new('run-1', function() return 'complete' end)
        local cleanup_service = service(index)
        local first = register(cleanup_service, index)
        local second_owner = {owner_scope=OwnerScope.SUITE_EXECUTION,
            service_run_id='run-1', suite_execution_id='suite-2'}
        local second_plan = index:validate_plan(second_owner, 'command-2',
            CleanupLifetime.OWNER, {{claim_key='other', resource_kind='item',
                resource_identity='item-2', exclusive=true}})
        local lease = cleanup_service:begin_mutation('command-2')
        local second = cleanup_service:register({owner=second_owner,
            command_invocation_id='command-2', label='destroy other',
            lifetime=CleanupLifetime.OWNER, receipt={item_id='item-2'},
            plan=second_plan, bindings={{claim_key='other'}}, mutation_lease=lease,
            restore=function() end,
            verify=function() return true end})
        lease:release()
        assert.are_not.equal(first:transaction_id(), second:transaction_id())
        assert.are.equal(1, first:registration_ordinal())
        assert.are.equal(1, second:registration_ordinal())
    end)

    it('retains history after verified execution releases pending claims', function()
        local index = ResourceDependencyIndex.new('run-1', function() return 'complete' end)
        local cleanup_service = service(index)
        local transaction = register(cleanup_service, index)
        assert.is_true(transaction:execute('manual'))
        assert.is_false(transaction:isPending())
        assert.are.equal(0, #transaction:claimReferences())
        local journal = cleanup_service:journal()
        assert.same({'cleanup.transaction_registered', 'cleanup.transaction_started',
            'cleanup.transaction_finished'}, {journal[1].event, journal[2].event,
            journal[3].event})
        assert.are.equal('complete', journal[3].details.disposition)
        assert.is_false(transaction:execute('manual'))
        assert.are.equal(3, #cleanup_service:journal())
    end)

    it('closes an owner after finalizing its pending transactions', function()
        local index = ResourceDependencyIndex.new('run-1', function() return 'complete' end)
        local cleanup_service = service(index)
        register(cleanup_service, index)
        local confirmed, result = cleanup_service:finalize_owner(owner(),
            'test teardown')
        assert.is_true(confirmed)
        assert.is_true(result.confirmed)
        assert.same(result, cleanup_service:owner_result(owner()))
        assert_error(function() register(cleanup_service, index) end,
            'registration is closed')
    end)

    it('attempts safe owner cleanup before terminalizing interruption work', function()
        local index = ResourceDependencyIndex.new('run-1', function() return 'complete' end)
        local cleanup_service = service(index)
        local transaction = register(cleanup_service, index)
        local confirmed = cleanup_service:finalize_owner(owner(),
            'host abort', true)
        assert.is_true(confirmed)
        assert.equals('complete', transaction:state())
        local journal = cleanup_service:journal()
        assert.equals('complete', journal[#journal].details.disposition)
    end)

    it('retains unconfirmed claims and one terminal journal event after interruption',
            function()
        local index = ResourceDependencyIndex.new('run-1', function() return 'complete' end)
        local cleanup_service = service(index)
        local transaction = register(cleanup_service, index)
        CleanupTransaction._mark_unconfirmed(transaction, {reason='host interruption'})
        assert.are.equal('unconfirmed', transaction:state())
        assert.are.equal(1, #transaction:claimReferences())
        local journal = cleanup_service:journal()
        assert.are.equal('cleanup.transaction_finished', journal[#journal].event)
        assert.are.equal('unconfirmed', journal[#journal].details.disposition)
    end)

    it('records one failed terminal event and retains claims after cleanup failure',
            function()
        local index = ResourceDependencyIndex.new('run-1', function() return 'complete' end)
        local cleanup_service = service(index)
        local lease = cleanup_service:begin_mutation('command-1')
        local transaction = cleanup_service:register({owner=owner(),
            command_invocation_id='command-1', label='destroy item',
            lifetime=CleanupLifetime.COMMAND, receipt={item_id='item-1'},
            plan=plan(index), bindings={{claim_key='item'}}, mutation_lease=lease,
            restore=function() error('restore failed') end, verify=function() return true end})
        lease:release()
        assert_error(function() transaction:execute('teardown') end, 'restore')
        assert.are.equal('failed', transaction:state())
        assert.are.equal(1, #transaction:claimReferences())
        local journal = cleanup_service:journal()
        assert.are.equal('failed', journal[#journal].details.disposition)
    end)

    it('quarantines unresolved ownership when verified claim release fails', function()
        local index = ResourceDependencyIndex.new('run-1', function()
            error('release authorization failed')
        end)
        local quarantine = nil
        local cleanup_service = CleanupRegistrationService.new({service_run_id='run-1',
            resource_index=index, now_ms=function() return 10 end,
            quarantine=function(evidence) quarantine = evidence end})
        local transaction = register(cleanup_service, index)
        local succeeded = pcall(function() transaction:execute('teardown') end)
        assert.is_false(succeeded)
        assert.are.equal('failed', transaction:state())
        assert.are.equal('cleanup_claim_release_failed', quarantine.reason)
        assert.are.equal(transaction:transaction_id(), quarantine.transaction_id)
        assert.are.equal(1, #transaction:claimReferences())
    end)

    it('abandons only the current invocation pending transaction and publishes once',
            function()
        local index = ResourceDependencyIndex.new('run-1', function(_, proof)
            assert.are.equal('item-1', proof.absent_resources[1].resource_identity)
            return 'abandoned'
        end)
        local cleanup_service = service(index)
        local lease = cleanup_service:begin_mutation('command-1')
        local transaction = register(cleanup_service, index, lease)
        cleanup_service:abandonSelfRolledBack(transaction:transaction_id(), lease,
            absence_proof('item-1'))
        lease:release()
        assert.are.equal('abandoned', transaction:state())
        assert.are.equal(0, #transaction:claimReferences())
        local journal = cleanup_service:journal()
        assert.are.equal('cleanup.transaction_abandoned', journal[#journal].event)
        assert_error(function()
            cleanup_service:abandonSelfRolledBack(transaction:transaction_id(),
                lease, absence_proof('item-1'))
        end, 'only pending')
    end)

    it('keeps an effect cleanup pending with conflicted ownership after post-effect registration failure',
            function()
        local index = ResourceDependencyIndex.new('run-1', function() return 'complete' end)
        local quarantine = nil
        local cleanup_service = CleanupRegistrationService.new({service_run_id='run-1',
            resource_index=index, now_ms=function() return 10 end,
            quarantine=function(evidence) quarantine = evidence end})
        local invalid_plan = {}
        local lease = cleanup_service:begin_mutation('command-1')
        assert_error(function()
            cleanup_service:register({owner=owner(), command_invocation_id='command-1',
                label='destroy item', lifetime=CleanupLifetime.COMMAND,
                receipt={item_id='item-1'}, plan=invalid_plan, mutation_lease=lease,
                bindings={{claim_key='item'}}, restore=function() end,
                verify=function() return true end})
        end, 'cleanup registration failed after effect')
        lease:release()
        local journal = cleanup_service:journal()
        assert.are.equal('cleanup.transaction_registered', journal[1].event)
        assert.is_true(journal[1].details.conflicted)
        assert.are.equal('post_effect_registration_failed', quarantine.reason)
        local pending_ids = cleanup_service:pending_ids_for(owner())
        assert.are.equal(1, (function()
            local count = 0
            for _ in pairs(pending_ids) do count = count + 1 end
            return count
        end)())
    end)

    it('rejects registration outside its active mutation lease and mismatched plan ownership',
            function()
        local index = ResourceDependencyIndex.new('run-1', function() return 'complete' end)
        local cleanup_service = service(index)
        assert_error(function()
            cleanup_service:register({owner=owner(), command_invocation_id='command-1',
                label='destroy item', lifetime=CleanupLifetime.COMMAND,
                receipt={item_id='item-1'}, plan=plan(index),
                bindings={{claim_key='item'}}, restore=function() end,
                verify=function() return true end})
        end, 'active mutation lease')
        local lease = cleanup_service:begin_mutation('command-1')
        local foreign_owner = {owner_scope=OwnerScope.SUITE_EXECUTION,
            service_run_id='run-1', suite_execution_id='suite-2'}
        assert_error(function()
            cleanup_service:register({owner=foreign_owner,
                command_invocation_id='command-1', label='destroy item',
                lifetime=CleanupLifetime.COMMAND, receipt={item_id='item-1'},
                plan=plan(index), bindings={{claim_key='item'}}, mutation_lease=lease,
                restore=function() end, verify=function() return true end})
        end, 'owner does not match')
        lease:release()
    end)

    it('excludes a competing mutating attempt across a cooperative yield',
            function()
        local index = ResourceDependencyIndex.new('run-1', function() return 'complete' end)
        local cleanup_service = service(index)
        local first
        local execution = coroutine.create(function()
            first = cleanup_service:begin_mutation('command-1')
            coroutine.yield()
            first:release()
        end)
        assert.is_true(coroutine.resume(execution))
        assert_error(function() cleanup_service:begin_mutation('command-2') end,
            'another mutating command attempt is active')
        assert.is_true(coroutine.resume(execution))
        local second = cleanup_service:begin_mutation('command-2')
        second:release()
    end)

    it('rejects a non-effect_absent abandonment proof', function()
        local index = ResourceDependencyIndex.new('run-1', function() return 'abandoned' end)
        local cleanup_service = service(index)
        local transaction = register(cleanup_service, index)
        assert_error(function()
            cleanup_service:abandonSelfRolledBack(transaction:transaction_id(),
                cleanup_service:begin_mutation('command-1'),
                {resource_kind='item', resource_identity='item-1'})
        end, 'command.effect_absent')
        assert.is_true(transaction:isPending())
    end)

    it('rejects absence proof identities that do not match the transaction claims',
            function()
        local index = ResourceDependencyIndex.new('run-1', function() return 'abandoned' end)
        local cleanup_service = service(index)
        local lease = cleanup_service:begin_mutation('command-1')
        local transaction = register(cleanup_service, index, lease)
        assert_error(function()
            cleanup_service:abandonSelfRolledBack(transaction:transaction_id(), lease,
                absence_proof('other-item'))
        end, 'does not match')
        assert.is_true(transaction:isPending())
        lease:release()
    end)
end)
