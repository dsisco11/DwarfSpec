-- Owns suite, test-attempt, and service cleanup registration windows.

local OwnerScope = require('dwarfspec.protocol.enums.execution_owner_scopes')

---@class dwarfspec.CleanupOwnerLifecycle
---@field private _service_run_id string
---@field private _cleanup_service dwarfspec.CleanupRegistrationService
---@field private _active_suite dwarfspec.ExecutionOwnerIdentity|nil
---@field private _active_test dwarfspec.ExecutionOwnerIdentity|nil
---@field private _next_test_attempt integer
local CleanupOwnerLifecycle = {}
CleanupOwnerLifecycle.__index = CleanupOwnerLifecycle

---@class dwarfspec.host.execution.CleanupOwnerLifecycleInternals
local Internals = {}

---Copies one owner identity without exposing internal mutable state.
---@param owner dwarfspec.ExecutionOwnerIdentity
---@return dwarfspec.ExecutionOwnerIdentity
function Internals.copy(owner)
    local result = {}
    for key, value in pairs(owner) do result[key] = value end
    return result
end

---Creates one owner lifecycle coordinator for an admitted service run.
---@param service_run_id string
---@param cleanup_service dwarfspec.CleanupRegistrationService
---@return dwarfspec.CleanupOwnerLifecycle
function CleanupOwnerLifecycle.new(service_run_id, cleanup_service)
    assert(type(service_run_id) == 'string' and service_run_id ~= '',
        'cleanup owner lifecycle requires a service run ID')
    assert(type(cleanup_service) == 'table' and
        type(cleanup_service.finalize_owner) == 'function',
        'cleanup owner lifecycle requires a cleanup registration service')
    return setmetatable({_service_run_id=service_run_id,
        _cleanup_service=cleanup_service, _active_suite=nil,
        _active_test=nil, _next_test_attempt=0}, CleanupOwnerLifecycle)
end

---Activates the cleanup owner for one selected spec-file execution.
---@param identity DwarfSpecFileSuiteIdentity
---@return dwarfspec.ExecutionOwnerIdentity
function CleanupOwnerLifecycle:suite_entry(identity)
    assert(self._active_suite == nil and self._active_test == nil,
        'cleanup owner lifecycle already has an active suite')
    assert(type(identity) == 'table' and type(identity.suite_id) == 'string' and
        identity.suite_id ~= '', 'cleanup owner lifecycle requires suite identity')
    self._active_suite = {owner_scope=OwnerScope.SUITE_EXECUTION,
        service_run_id=self._service_run_id, suite_execution_id=identity.suite_id}
    return Internals.copy(self._active_suite)
end

---Activates the nested cleanup owner before one example's setup hooks.
---@return dwarfspec.ExecutionOwnerIdentity
function CleanupOwnerLifecycle:test_entry()
    assert(self._active_suite ~= nil and self._active_test == nil,
        'cleanup test owner requires one active suite and no active test')
    self._next_test_attempt = self._next_test_attempt + 1
    self._active_test = {owner_scope=OwnerScope.TEST_ATTEMPT,
        service_run_id=self._service_run_id,
        suite_execution_id=self._active_suite.suite_execution_id,
        test_attempt_id=self._active_suite.suite_execution_id .. '#attempt=' ..
            tostring(self._next_test_attempt)}
    return Internals.copy(self._active_test)
end

---Returns the most-specific public cleanup owner or rejects out-of-window work.
---@return dwarfspec.ExecutionOwnerIdentity
function CleanupOwnerLifecycle:public_owner()
    assert(self._active_test ~= nil or self._active_suite ~= nil,
        'caller-initiated cleanup requires an active suite or test owner')
    return Internals.copy(self._active_test or self._active_suite)
end

---Finalizes the active test owner after its teardown hooks complete.
---@param reason string
---@param interrupted boolean|nil
---@return boolean, table|nil
function CleanupOwnerLifecycle:test_exit(reason, interrupted)
    local owner = self._active_test
    self._active_test = nil
    if owner == nil then return true, nil end
    return self._cleanup_service:finalize_owner(owner, reason, interrupted)
end

---Finalizes the active suite owner after its teardown hooks complete.
---@param reason string
---@param interrupted boolean|nil
---@return boolean, table|nil
function CleanupOwnerLifecycle:suite_exit(reason, interrupted)
    local test_ok = self:test_exit(reason, interrupted)
    local owner = self._active_suite
    self._active_suite = nil
    if owner == nil then return test_ok, nil end
    local suite_ok, result = self._cleanup_service:finalize_owner(owner,
        reason, interrupted)
    return test_ok and suite_ok, result
end

---Finalizes every open owner and then the internal service-run cleanup owner.
---@param reason string
---@param interrupted boolean|nil
---@return boolean
function CleanupOwnerLifecycle:finalize_all(reason, interrupted)
    local suite_ok = self:suite_exit(reason, interrupted)
    local service_owner = {owner_scope=OwnerScope.SERVICE_RUN,
        service_run_id=self._service_run_id}
    local service_ok = self._cleanup_service:finalize_owner(service_owner,
        reason, interrupted)
    return suite_ok and service_ok
end

return CleanupOwnerLifecycle
