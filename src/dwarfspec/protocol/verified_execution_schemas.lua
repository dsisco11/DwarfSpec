-- Structural validators for the coordinated verified-execution revision.

local CleanupDisposition = require(
    'dwarfspec.protocol.enums.cleanup_terminal_dispositions')
local CleanupLifetime = require('dwarfspec.protocol.enums.cleanup_lifetimes')
local CleanupState = require('dwarfspec.protocol.enums.cleanup_states')
local CleanupTrigger = require(
    'dwarfspec.protocol.enums.cleanup_execution_triggers')
local CommandFailureStage = require(
    'dwarfspec.protocol.enums.command_failure_stages')
local CleanupOwnerScope = require(
    'dwarfspec.protocol.enums.cleanup_owner_scopes')
local ExecutionOwnerScope = require(
    'dwarfspec.protocol.enums.execution_owner_scopes')
local Revision = require('dwarfspec.protocol.verified_execution_revision')

---@class dwarfspec.VerifiedExecutionSchemas
local Schemas = {}
Schemas.__index = Schemas

---Requires a nonempty string field.
---@param value table
---@param field string
---@param label string
function Schemas:_string(value, field, label)
    assert(type(value[field]) == 'string' and value[field] ~= '',
        label .. ' requires ' .. field)
end

---Returns whether a value belongs to an immutable enum.
---@param enum table
---@param value any
---@return boolean
function Schemas:_enum_contains(enum, value)
    for _, candidate in pairs(enum) do
        if candidate == value then return true end
    end
    return false
end

---Validates one owner scope and its corresponding identity.
---@param value table
---@param scope_enum table
---@param label string
function Schemas:_owner(value, scope_enum, label)
    assert(self:_enum_contains(scope_enum, value.owner_scope),
        label .. ' has unsupported owner_scope')
    self:_string(value, 'service_run_id', label)
    if value.owner_scope == scope_enum.SUITE_EXECUTION then
        self:_string(value, 'suite_execution_id', label)
        assert(value.test_attempt_id == nil,
            label .. ' suite owner cannot identify a test attempt')
    elseif value.owner_scope == scope_enum.TEST_ATTEMPT then
        self:_string(value, 'suite_execution_id', label)
        self:_string(value, 'test_attempt_id', label)
    else
        assert(value.suite_execution_id == nil and
            value.test_attempt_id == nil,
            label .. ' service owner cannot identify suite or test owners')
    end
end

---Validates command ancestry and owner identity fields.
---@param value table
---@return table
function Schemas:validate_command_identity(value)
    assert(type(value) == 'table', 'command identity must be a table')
    self:_string(value, 'invocation_id', 'command identity')
    self:_string(value, 'root_invocation_id', 'command identity')
    assert(not (value.parent_invocation_id ~= nil and
        value.parent_cleanup_transaction_id ~= nil),
        'command identity cannot have both parent kinds')
    if value.parent_invocation_id ~= nil then
        self:_string(value, 'parent_invocation_id', 'command identity')
    end
    if value.parent_cleanup_transaction_id ~= nil then
        self:_string(value, 'parent_cleanup_transaction_id',
            'command identity')
    end
    self:_owner(value, ExecutionOwnerScope, 'command identity')
    return value
end

---Validates one command lifecycle event in the successor event schema.
---@param value table
---@return table
function Schemas:validate_command_event(value)
    assert(type(value) == 'table', 'command event must be a table')
    assert(value.schema == Revision.EVENT_SCHEMA and
        value.protocol_version == Revision.PROTOCOL_VERSION,
        'command event has unsupported verified-execution revision')
    self:validate_command_identity(value.command)
    self:_string(value, 'event_type', 'command event')
    if value.failure_stage ~= nil then
        assert(self:_enum_contains(CommandFailureStage, value.failure_stage),
            'command event has unsupported failure_stage')
    end
    return value
end

---Validates one cleanup lifecycle event in the successor event schema.
---@param value table
---@return table
function Schemas:validate_cleanup_event(value)
    assert(type(value) == 'table', 'cleanup event must be a table')
    assert(value.schema == Revision.EVENT_SCHEMA and
        value.protocol_version == Revision.PROTOCOL_VERSION,
        'cleanup event has unsupported verified-execution revision')
    self:_string(value, 'transaction_id', 'cleanup event')
    self:_string(value, 'event_type', 'cleanup event')
    self:_string(value, 'label', 'cleanup event')
    assert(type(value.registration_ordinal) == 'number' and
        value.registration_ordinal >= 1 and
        value.registration_ordinal % 1 == 0,
        'cleanup event requires a positive registration_ordinal')
    assert(self:_enum_contains(CleanupLifetime, value.lifetime),
        'cleanup event has unsupported lifetime')
    self:_owner(value, CleanupOwnerScope, 'cleanup event')
    if value.owner_scope ~= CleanupOwnerScope.SERVICE_RUN then
        assert(type(value.repeat_index) == 'number' and
            value.repeat_index >= 1 and value.repeat_index % 1 == 0,
            'cleanup event requires a positive repeat_index')
        self:_string(value, 'spec_file_identity', 'cleanup event')
    end
    if value.owner_scope == CleanupOwnerScope.TEST_ATTEMPT then
        self:_string(value, 'test_identity', 'cleanup event')
    end
    assert(self:_enum_contains(CleanupState, value.state),
        'cleanup event has unsupported state')
    assert(type(value.registered_at_ms) == 'number',
        'cleanup event requires registered_at_ms')
    if value.command_invocation_id ~= nil then
        self:_string(value, 'command_invocation_id', 'cleanup event')
    end
    if value.event_type == 'cleanup.transaction_started' or
            value.event_type == 'cleanup.transaction_finished' then
        assert(self:_enum_contains(CleanupTrigger, value.trigger),
            'cleanup execution event has unsupported trigger')
        assert(type(value.execution_started_at_ms) == 'number',
            'cleanup execution event requires execution_started_at_ms')
    end
    if value.event_type == 'cleanup.transaction_finished' then
        assert(value.disposition ~= CleanupDisposition.ABANDONED and
            self:_enum_contains(CleanupDisposition, value.disposition),
            'cleanup finished event has unsupported disposition')
        assert(type(value.completed_at_ms) == 'number',
            'cleanup finished event requires completed_at_ms')
        self:_string(value, 'restore_outcome', 'cleanup finished event')
        self:_string(value, 'verification_outcome',
            'cleanup finished event')
    elseif value.event_type == 'cleanup.transaction_abandoned' then
        assert(value.disposition == CleanupDisposition.ABANDONED,
            'cleanup abandoned event requires abandoned disposition')
        assert(type(value.completed_at_ms) == 'number',
            'cleanup abandoned event requires completed_at_ms')
        assert(type(value.evidence) == 'table',
            'cleanup abandoned event requires bounded evidence')
    else
        assert(value.event_type == 'cleanup.transaction_registered' or
            value.event_type == 'cleanup.transaction_started',
            'cleanup event has unsupported event_type')
    end
    return value
end

---Validates one terminal cleanup result record.
---@param value table
---@return table
function Schemas:validate_cleanup_result(value)
    assert(type(value) == 'table', 'cleanup result must be a table')
    self:_string(value, 'transaction_id', 'cleanup result')
    self:_string(value, 'label', 'cleanup result')
    assert(type(value.registration_ordinal) == 'number' and
        value.registration_ordinal >= 1 and
        value.registration_ordinal % 1 == 0,
        'cleanup result requires a positive registration_ordinal')
    assert(self:_enum_contains(CleanupLifetime, value.lifetime),
        'cleanup result has unsupported lifetime')
    self:_owner(value, CleanupOwnerScope, 'cleanup result')
    assert(self:_enum_contains(CleanupDisposition, value.disposition),
        'cleanup result has unsupported disposition')
    assert(type(value.registered_at_ms) == 'number',
        'cleanup result requires registered_at_ms')
    assert(type(value.completed_at_ms) == 'number',
        'cleanup result requires completed_at_ms')
    if value.disposition == CleanupDisposition.ABANDONED then
        assert(type(value.evidence) == 'table',
            'abandoned cleanup result requires bounded evidence')
    else
        self:_string(value, 'restore_outcome', 'cleanup result')
        self:_string(value, 'verification_outcome', 'cleanup result')
    end
    if value.command_invocation_id ~= nil then
        self:_string(value, 'command_invocation_id', 'cleanup result')
    end
    return value
end

---Validates one suite execution record and its cleanup projection.
---@param value table
---@return table
function Schemas:validate_suite_execution(value)
    assert(type(value) == 'table', 'suite execution must be a table')
    self:_string(value, 'service_run_id', 'suite execution')
    self:_string(value, 'suite_execution_id', 'suite execution')
    assert(type(value.repeat_index) == 'number' and value.repeat_index >= 1 and
        value.repeat_index % 1 == 0,
        'suite execution requires a positive repeat_index')
    self:_string(value, 'spec_file_identity', 'suite execution')
    assert(type(value.behavior_summary) == 'table',
        'suite execution requires behavior_summary')
    self:_string(value, 'cleanup_outcome', 'suite execution')
    assert(type(value.cleanup_transactions) == 'table',
        'suite execution requires cleanup_transactions')
    for _, transaction in ipairs(value.cleanup_transactions) do
        self:validate_cleanup_result(transaction)
        assert(transaction.owner_scope == CleanupOwnerScope.SUITE_EXECUTION and
            transaction.service_run_id == value.service_run_id and
            transaction.suite_execution_id == value.suite_execution_id,
            'suite cleanup transaction has inconsistent ownership')
    end
    return value
end

---Validates one test attempt record and its cleanup projection.
---@param value table
---@return table
function Schemas:validate_test_attempt(value)
    assert(type(value) == 'table', 'test attempt must be a table')
    self:_string(value, 'service_run_id', 'test attempt')
    self:_string(value, 'test_attempt_id', 'test attempt')
    self:_string(value, 'suite_execution_id', 'test attempt')
    self:_string(value, 'test_identity', 'test attempt')
    assert(type(value.repeat_index) == 'number' and value.repeat_index >= 1 and
        value.repeat_index % 1 == 0,
        'test attempt requires a positive repeat_index')
    assert(type(value.cleanup_transactions) == 'table',
        'test attempt requires cleanup_transactions')
    for _, transaction in ipairs(value.cleanup_transactions) do
        self:validate_cleanup_result(transaction)
        assert(transaction.owner_scope == CleanupOwnerScope.TEST_ATTEMPT and
            transaction.service_run_id == value.service_run_id and
            transaction.test_attempt_id == value.test_attempt_id and
            transaction.suite_execution_id == value.suite_execution_id,
            'test cleanup transaction has inconsistent ownership')
    end
    return value
end

---Validates the structural result projections introduced by revision 3.
---@param value table
---@return table
function Schemas:validate_host_report(value)
    assert(type(value) == 'table', 'host report must be a table')
    assert(value.schema == Revision.RESULT_SCHEMA,
        'host report has unsupported verified-execution schema')
    assert(value.protocol_version == Revision.PROTOCOL_VERSION,
        'host report has unsupported verified-execution protocol')
    self:_string(value, 'service_run_id', 'host report')
    assert(type(value.service_cleanup_transactions) == 'table' and
        type(value.suite_executions) == 'table' and
        type(value.test_attempts) == 'table',
        'host report requires all cleanup result projections')
    local transaction_ids = {}
    ---Records one transaction identity and rejects duplicate projections.
    ---@param transaction table
    local function validate_unique(transaction)
        assert(not transaction_ids[transaction.transaction_id],
            'cleanup transaction must appear exactly once in result projections')
        transaction_ids[transaction.transaction_id] = true
    end
    for _, transaction in ipairs(value.service_cleanup_transactions) do
        self:validate_cleanup_result(transaction)
        validate_unique(transaction)
        assert(transaction.owner_scope == CleanupOwnerScope.SERVICE_RUN and
            transaction.service_run_id == value.service_run_id,
            'service cleanup transaction has inconsistent ownership')
    end
    for _, suite in ipairs(value.suite_executions) do
        assert(suite.service_run_id == value.service_run_id,
            'suite execution has inconsistent service ownership')
        self:validate_suite_execution(suite)
        for _, transaction in ipairs(suite.cleanup_transactions) do
            validate_unique(transaction)
        end
    end
    for _, attempt in ipairs(value.test_attempts) do
        assert(attempt.service_run_id == value.service_run_id,
            'test attempt has inconsistent service ownership')
        self:validate_test_attempt(attempt)
        for _, transaction in ipairs(attempt.cleanup_transactions) do
            validate_unique(transaction)
        end
    end
    return value
end

---Creates the stateless structural validator.
---@return dwarfspec.VerifiedExecutionSchemas
function Schemas.new()
    return setmetatable({}, Schemas)
end

return Schemas
