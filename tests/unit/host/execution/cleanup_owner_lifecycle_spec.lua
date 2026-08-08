-- Unit contracts for cleanup ownership activation and finalization.

local CleanupOwnerLifecycle = require(
    'dwarfspec.host.execution.cleanup_owner_lifecycle')
local OwnerScope = require('dwarfspec.protocol.enums.execution_owner_scopes')
local events = require('dwarfspec.protocol.events')

---@param callback fun()
---@param expected string
local function assert_error(callback, expected)
    local succeeded, message = pcall(callback)
    assert.is_false(succeeded)
    assert.is_truthy(tostring(message):find(expected, 1, true))
end

---@return table, table
local function lifecycle()
    local calls = {}
    local service = {finalize_owner=function(_, owner, reason, interrupted)
        calls[#calls + 1] = {owner=owner, reason=reason,
            interrupted=interrupted}
        return true, {owner=owner, confirmed=true}
    end}
    return CleanupOwnerLifecycle.new('run-1', service, events.new_journal({
        service_instance_id='service-1', project_id='project-1', run_id='run-1',
        generation=1, admitted_at_ms=0})), calls
end

---Returns one complete suite identity for ownership tests.
---@return table
local function suite_identity()
    return {suite_id='spec/a.lua#repeat=1', repeat_index=1,
        source_identity='spec/a.lua'}
end

---Opens the current test owner with a stable test identity.
---@param owner_lifecycle dwarfspec.CleanupOwnerLifecycle
local function enter_test(owner_lifecycle)
    owner_lifecycle:test_start({example_name='example'})
    owner_lifecycle:test_entry()
end

describe('CleanupOwnerLifecycle', function()
    it('selects a nested test owner over its active suite owner', function()
        local owner_lifecycle = lifecycle()
        owner_lifecycle:suite_entry(suite_identity())
        local suite_owner = owner_lifecycle:public_owner()
        assert.equals(OwnerScope.SUITE_EXECUTION, suite_owner.owner_scope)
        enter_test(owner_lifecycle)
        local test_owner = owner_lifecycle:public_owner()
        assert.equals(OwnerScope.TEST_ATTEMPT, test_owner.owner_scope)
        assert.equals(suite_owner.suite_execution_id,
            test_owner.suite_execution_id)
    end)

    it('finalizes test, suite, and service owners in lifecycle order', function()
        local owner_lifecycle, calls = lifecycle()
        owner_lifecycle:suite_entry(suite_identity())
        enter_test(owner_lifecycle)
        assert.is_true(owner_lifecycle:finalize_all('run complete'))
        assert.same({OwnerScope.TEST_ATTEMPT, OwnerScope.SUITE_EXECUTION,
            OwnerScope.SERVICE_RUN}, {calls[1].owner.owner_scope,
            calls[2].owner.owner_scope, calls[3].owner.owner_scope})
        assert.equals('run complete', calls[1].reason)
    end)

    it('rejects public ownership outside an active suite', function()
        local owner_lifecycle = lifecycle()
        assert_error(function() owner_lifecycle:public_owner() end,
            'active suite or test owner')
    end)

    it('propagates interruption to unresolved owner finalization', function()
        local owner_lifecycle, calls = lifecycle()
        owner_lifecycle:suite_entry(suite_identity())
        enter_test(owner_lifecycle)
        owner_lifecycle:test_exit('interrupted', true)
        assert.is_true(calls[1].interrupted)
    end)
end)
