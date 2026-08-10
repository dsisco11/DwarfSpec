-- Owns suite, test-attempt, and service cleanup registration windows.

local OwnerScope = require('dwarfspec.protocol.enums.execution_owner_scopes')
local Revision = require('dwarfspec.protocol.verified_execution_revision')
local materializer = require(
    'dwarfspec.host.execution.cleanup_result_materializer')

---@class dwarfspec.CleanupOwnerLifecycle
---@field private _service_run_id string
---@field private _cleanup_service dwarfspec.CleanupRegistrationService
---@field private _active_suite dwarfspec.ExecutionOwnerIdentity|nil
---@field private _active_test dwarfspec.ExecutionOwnerIdentity|nil
---@field private _next_test_attempt integer
---@field private _event_journal table
---@field private _suite_executions dwarfspec.SuiteExecutionResult[]
---@field private _test_attempts dwarfspec.TestAttemptResult[]
---@field private _next_test_identity? BustedExampleIdentity
---@field private _awaiting_test_status boolean
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
function CleanupOwnerLifecycle.new(service_run_id, cleanup_service, event_journal)
    assert(type(service_run_id) == 'string' and service_run_id ~= '',
        'cleanup owner lifecycle requires a service run ID')
    assert(type(cleanup_service) == 'table' and
        type(cleanup_service.finalize_owner) == 'function',
        'cleanup owner lifecycle requires a cleanup registration service')
    assert(type(event_journal) == 'table' and type(event_journal.events) == 'table',
        'cleanup owner lifecycle requires the authoritative event journal')
    return setmetatable({_service_run_id=service_run_id,
        _cleanup_service=cleanup_service, _active_suite=nil,
        _active_test=nil, _next_test_attempt=0, _event_journal=event_journal,
        _suite_executions={}, _test_attempts={}, _next_test_identity=nil,
        _awaiting_test_status=false},
        CleanupOwnerLifecycle)
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
        service_run_id=self._service_run_id, suite_execution_id=identity.suite_id,
        repeat_index=identity.repeat_index,
        spec_file_identity=identity.source_identity}
    self._suite_executions[#self._suite_executions + 1] = {
        service_run_id=self._service_run_id, suite_execution_id=identity.suite_id,
        repeat_index=identity.repeat_index,
        spec_file_identity=identity.source_identity,
        behavior_summary={successes=0, failures=0, errors=0, pending=0},
        cleanup_outcome='pending', cleanup_transactions={},
    }
    return Internals.copy(self._active_suite)
end

---Activates the nested cleanup owner before one example's setup hooks.
---@return dwarfspec.ExecutionOwnerIdentity
function CleanupOwnerLifecycle:test_entry()
    assert(self._active_suite ~= nil and self._active_test == nil,
        'cleanup test owner requires one active suite and no active test')
    assert(not self._awaiting_test_status,
        'cleanup test owner requires the preceding behavior status')
    self._next_test_attempt = self._next_test_attempt + 1
    local identity = assert(self._next_test_identity,
        'cleanup test owner requires test-start identity before setup')
    self._next_test_identity = nil
    self._active_test = {owner_scope=OwnerScope.TEST_ATTEMPT,
        service_run_id=self._service_run_id,
        suite_execution_id=self._active_suite.suite_execution_id,
        test_attempt_id=self._active_suite.suite_execution_id .. '#attempt=' ..
            tostring(self._next_test_attempt),
        repeat_index=self._active_suite.repeat_index,
        spec_file_identity=self._active_suite.spec_file_identity,
        test_identity=identity.example_name}
    self._test_attempts[#self._test_attempts + 1] = {
        service_run_id=self._service_run_id,
        suite_execution_id=self._active_suite.suite_execution_id,
        test_attempt_id=self._active_test.test_attempt_id,
        repeat_index=self._active_suite.repeat_index,
        test_identity=identity.example_name, cleanup_transactions={},
    }
    self._awaiting_test_status = true
    return Internals.copy(self._active_test)
end

---Records the stable Busted identity to be consumed by the next test setup.
---@param identity BustedExampleIdentity
function CleanupOwnerLifecycle:test_start(identity)
    assert(type(identity) == 'table' and type(identity.example_name) == 'string' and
        identity.example_name ~= '',
        'cleanup owner lifecycle requires a test-start identity')
    self._next_test_identity = {example_name=identity.example_name,
        source_identity=identity.source_identity}
end

---Records the final Busted behavior status for the latest closed attempt.
---@param status string
function CleanupOwnerLifecycle:test_finished(status)
    local attempt = self._test_attempts[#self._test_attempts]
    local suite = self._suite_executions[#self._suite_executions]
    assert(self._awaiting_test_status and attempt ~= nil and suite ~= nil and
            attempt.behavior_status == nil,
        'cleanup owner lifecycle has no completed test attempt')
    local count_key = ({
        success='successes', failure='failures', error='errors', pending='pending',
    })[status]
    assert(count_key ~= nil,
        'cleanup owner lifecycle received an unsupported test status')
    attempt.behavior_status = status
    self._awaiting_test_status = false
    suite.behavior_summary[count_key] = suite.behavior_summary[count_key] + 1
end

---Materializes the authoritative ledger for a closed owner.
---@param owner dwarfspec.ExecutionOwnerIdentity
---@return dwarfspec.CleanupTransactionResult[]
function CleanupOwnerLifecycle:_materialize(owner)
    return materializer.fold_owner(self._event_journal.events, owner)
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
    local confirmed, result = self._cleanup_service:finalize_owner(owner,
        reason, interrupted)
    local attempt = self._test_attempts[#self._test_attempts]
    attempt.cleanup_transactions = self:_materialize(owner)
    return confirmed, result
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
    local suite = self._suite_executions[#self._suite_executions]
    suite.cleanup_transactions = self:_materialize(owner)
    suite.cleanup_outcome = suite_ok and 'complete' or 'failed'
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

---Returns the detached terminal host report derived from the event journal.
---@return dwarfspec.VerifiedExecutionHostReport
function CleanupOwnerLifecycle:host_report()
    local service_owner = {owner_scope=OwnerScope.SERVICE_RUN,
        service_run_id=self._service_run_id}
    local report = {schema=Revision.RESULT_SCHEMA,
        protocol_version=Revision.PROTOCOL_VERSION,
        service_run_id=self._service_run_id,
        service_cleanup_transactions=self:_materialize(service_owner),
        suite_executions=require('dwarfspec.protocol.events').copy_json(
            self._suite_executions, 'suite cleanup result projections'),
        test_attempts=require('dwarfspec.protocol.events').copy_json(
            self._test_attempts, 'test cleanup result projections')}
    require('dwarfspec.protocol.verified_execution_schemas').new()
        :validate_cleanup_projections(report, self._event_journal.events)
    return report
end

---Returns the latest materialized suite execution for event publication.
---@return dwarfspec.SuiteExecutionResult
function CleanupOwnerLifecycle:latest_suite()
    local suite = assert(self._suite_executions[#self._suite_executions],
        'cleanup owner lifecycle has no materialized suite execution')
    return require('dwarfspec.protocol.events').copy_json(suite,
        'materialized suite execution')
end

return CleanupOwnerLifecycle
