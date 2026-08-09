-- Structured, bounded, append-only event journals for automation runs.

local EventType = require('dwarfspec.protocol.enums.event_types')
local focus_diagnostics =
    require('dwarfspec.protocol.diagnostics.focus')
local RunState = require('dwarfspec.protocol.enums.run_states')
local SchedulerFailureKind =
    require('dwarfspec.protocol.enums.scheduler_failure_kinds')
local TestStatus = require('dwarfspec.protocol.enums.test_statuses')

local M = {
    schema='dwarfspec.event.v3',
}

local DEFAULT_LIMITS = {
    max_depth=16,
    max_nodes=100000,
    max_string_bytes=65536,
}

local PAYLOAD_FIELDS = {
    [EventType.RUN_QUEUED]={
        selection='table',
        queue_admitted_ms='integer',
        owner_kind='string',
    },
    [EventType.RUN_ACTIVATED]={queue_wait_ms='integer'},
    [EventType.RUN_CANCELLED]={reason='string', owner='string'},
    [EventType.RUN_STARTED]={repeat_count='integer', options='table'},
    [EventType.REPEAT_STARTED]={repeat_index='integer', repeat_count='integer'},
    [EventType.REPEAT_FINISHED]={repeat_index='integer', counts='table'},
    [EventType.SUITE_FINISHED]={
        suite_execution_id='string',
        repeat_index='integer',
        spec_file_identity='string',
        behavior_summary='table',
        cleanup_outcome='string',
    },
    [EventType.TEST_STARTED]={name='string'},
    [EventType.TEST_FINISHED]={
        name='string',
        status='string',
        duration_ms='integer',
    },
    [EventType.PROBLEM_RECORDED]={
        kind='string',
        name='string',
        message='string',
    },
    [EventType.COMMAND_STARTED]={
        name='string',
        subject_identity='string',
        safe_arguments='table',
    },
    [EventType.COMMAND_FINISHED]={
        name='string',
        status='string',
        duration_ms='integer',
    },
    [EventType.DIAGNOSTIC_RECORDED]={kind='string', content='table'},
    [EventType.CLEANUP_STARTED]={
        reason='string',
        pending_action_count='integer',
    },
    [EventType.CLEANUP_FAILED]={
        action_name='string',
        reason='string',
        message='string',
    },
    [EventType.CLEANUP_FINISHED]={
        cleanup_confirmed='boolean',
        mount_cleanup_verified='boolean',
    },
    [EventType.COMMAND_STAGE]={
        name='string',
        stage='string',
        status='string',
        duration_ms='integer',
        configured_timeout_ms='integer',
        attempt='integer',
        command='table',
    },
    [EventType.CLEANUP_TRANSACTION_REGISTERED]={cleanup_event='table'},
    [EventType.CLEANUP_TRANSACTION_STARTED]={cleanup_event='table'},
    [EventType.CLEANUP_TRANSACTION_FINISHED]={cleanup_event='table'},
    [EventType.CLEANUP_TRANSACTION_ABANDONED]={cleanup_event='table'},
    [EventType.RUN_ABORTED]={reason='string'},
    [EventType.RUN_FINISHED]={
        terminal_state='string',
        totals='table',
        cleanup_required='boolean',
        cleanup_confirmed='boolean',
    },
    [EventType.SCHEDULER_BLOCKED]={reason='string'},
}

local TERMINAL_RUN_STATES = {
    [RunState.PASSED]=true,
    [RunState.FAILED]=true,
    [RunState.ABORTED]=true,
    [RunState.CANCELLED]=true,
}

local TEST_STATUSES = {
    [TestStatus.SUCCESS]=true,
    [TestStatus.FAILURE]=true,
    [TestStatus.ERROR]=true,
    [TestStatus.PENDING]=true,
}

local COMMAND_STAGES = {
    preflight=true,
    attempt=true,
    intrinsic_verification=true,
    caller_verification=true,
    command_cleanup=true,
    completion=true,
}

local COMMAND_STAGE_STATUSES = {
    preflight={pending=true, passed=true, fatal=true, failed=true,
        timed_out=true},
    attempt={started=true, retry=true, completed=true, failed=true,
        timed_out=true},
    intrinsic_verification={pending=true, passed=true, fatal=true, failed=true,
        timed_out=true},
    caller_verification={pending=true, passed=true, fatal=true, failed=true,
        timed_out=true},
    command_cleanup={attempted=true, verified=true, failed=true,
        timed_out=true},
    completion={completed=true, failed=true},
}

local TERMINAL_EVIDENCE_KINDS = {
    intrinsic_and_caller=true,
    intrinsic_only=true,
    execution_receipt_only=true,
}

---Returns whether a value is a nonnegative integer.
---@param value any
---@return boolean
local function is_nonnegative_integer(value)
    return type(value) == 'number' and value >= 0 and value % 1 == 0
end

---Returns whether a value is a positive integer.
---@param value any
---@return boolean
local function is_positive_integer(value)
    return is_nonnegative_integer(value) and value > 0
end

---Validates optional structured fields on one problem record.
---@param payload table
---@param path string|nil
---@return table
function M.validate_problem(payload, path)
    path = path or 'problem'
    assert(type(payload) == 'table', path .. ' must be a table')
    if payload.source_identity ~= nil then
        assert(type(payload.source_identity) == 'string' and
            payload.source_identity ~= '',
            path .. '.source_identity must be a nonempty string')
    end
    if payload.line ~= nil then
        assert(is_positive_integer(payload.line),
            path .. '.line must be a positive integer')
    end
    if payload.column ~= nil then
        assert(is_positive_integer(payload.column),
            path .. '.column must be a positive integer')
        assert(payload.line ~= nil,
            path .. '.column requires line')
    end
    return payload
end

---Validates one typed required field.
---@param value any
---@param expected_type string
---@param path string
local function validate_typed_field(value, expected_type, path)
    if expected_type == 'integer' then
        assert(is_nonnegative_integer(value),
            path .. ' must be a nonnegative integer')
    else
        assert(type(value) == expected_type,
            path .. ' must be a ' .. expected_type)
    end
end

---Validates a complete Busted count record.
---@param counts table
---@param path string
local function validate_counts(counts, path)
    for _, field in ipairs({
            'successes', 'failures', 'errors', 'pending'}) do
        assert(is_nonnegative_integer(counts[field]),
            path .. '.' .. field .. ' must be a nonnegative integer')
    end
end

---Returns normalized bounds for one JSON-safe copy operation.
---@param limits table|nil
---@return table
local function normalized_limits(limits)
    local result = {}
    for name, fallback in pairs(DEFAULT_LIMITS) do
        local value = limits and limits[name] or fallback
        assert(is_nonnegative_integer(value) and value > 0,
            'event copy limit ' .. name .. ' must be a positive integer')
        result[name] = value
    end
    return result
end

---Returns the JSON container kind and maximum array index.
---@param value table
---@param path string
---@return string, integer
local function container_kind(value, path)
    local string_keys = 0
    local numeric_keys = 0
    local maximum = 0
    for key in pairs(value) do
        if type(key) == 'string' then
            assert(key ~= 'owner_capability',
                'owner capability is forbidden at ' .. path)
            string_keys = string_keys + 1
        elseif type(key) == 'number' and key >= 1 and key % 1 == 0 then
            numeric_keys = numeric_keys + 1
            maximum = math.max(maximum, key)
        else
            error(('JSON-safe table %s has unsupported key %s')
                :format(path, tostring(key)), 0)
        end
    end
    assert(string_keys == 0 or numeric_keys == 0,
        'JSON-safe table ' .. path .. ' mixes object and array keys')
    if numeric_keys > 0 then
        assert(maximum == numeric_keys,
            'JSON-safe array ' .. path .. ' must be dense')
        return 'array', maximum
    end
    return 'object', string_keys
end

---Returns a harmless JSON container marker or rejects a behavioral metatable.
---@param value table
---@param path string
---@return string|nil
local function json_container_marker(value, path)
    local metatable = getmetatable(value)
    if metatable == nil then return nil end
    assert(type(metatable) == 'table',
        'JSON-safe table has a protected metatable at ' .. path)
    local marker = metatable.__jsontype
    local field_count = 0
    for _ in next, metatable do field_count = field_count + 1 end
    assert(field_count == 1 and
        (marker == 'array' or marker == 'object'),
        'JSON-safe table must not have a behavioral metatable at ' .. path)
    return marker
end

---Copies one bounded JSON-safe value.
---@param value any
---@param path string
---@param depth integer
---@param context table
---@return any
local function copy_value(value, path, depth, context)
    assert(depth <= context.limits.max_depth,
        'JSON-safe value exceeds maximum depth at ' .. path)
    context.nodes = context.nodes + 1
    assert(context.nodes <= context.limits.max_nodes,
        'JSON-safe value exceeds maximum node count at ' .. path)

    local value_type = type(value)
    if value_type == 'nil' or value_type == 'boolean' then return value end
    if value_type == 'string' then
        assert(#value <= context.limits.max_string_bytes,
            'JSON-safe string exceeds maximum byte length at ' .. path)
        return value
    end
    if value_type == 'number' then
        assert(value == value and value ~= math.huge and value ~= -math.huge,
            'JSON-safe number must be finite at ' .. path)
        return value
    end
    assert(value_type == 'table',
        ('JSON-safe value %s has unsupported type %s')
            :format(path, value_type))
    local marker = json_container_marker(value, path)
    assert(context.active[value] == nil,
        'JSON-safe value contains a cycle at ' .. path)

    context.active[value] = true
    local result = {}
    local kind, maximum = container_kind(value, path)
    if kind == 'array' then
        for index = 1, maximum do
            result[index] = copy_value(value[index],
                ('%s[%d]'):format(path, index), depth + 1, context)
        end
    else
        for key, child in pairs(value) do
            result[key] = copy_value(child, path .. '.' .. key,
                depth + 1, context)
        end
    end
    context.active[value] = nil
    if marker ~= nil then setmetatable(result, {__jsontype=marker}) end
    return result
end

---Returns a detached bounded JSON-safe copy.
---@param value any
---@param path string|nil
---@param limits table|nil
---@return any
function M.copy_json(value, path, limits)
    return copy_value(value, path or 'value', 0, {
        active={},
        limits=normalized_limits(limits),
        nodes=0,
    })
end

---Validates the payload contract for one initial event type.
---@param event_type table|string
---@param payload table
function M.validate_payload(event_type, payload)
    local identifier = tostring(event_type)
    local fields = PAYLOAD_FIELDS[event_type]
    assert(fields ~= nil, 'unsupported automation event type: ' ..
        identifier)
    assert(type(payload) == 'table',
        'event payload must be a table for ' .. identifier)
    M.copy_json(payload, 'event payload')
    for field, expected_type in pairs(fields) do
        assert(payload[field] ~= nil,
            ('event payload for %s is missing field: %s')
                :format(identifier, field))
        validate_typed_field(payload[field], expected_type,
            ('event payload %s.%s'):format(identifier, field))
    end
    if event_type == EventType.RUN_FINISHED then
        assert(TERMINAL_RUN_STATES[payload.terminal_state] == true,
            'event payload run.finished has invalid terminal state')
    elseif event_type == EventType.TEST_FINISHED then
        assert(TEST_STATUSES[payload.status] == true,
            'event payload test.finished has invalid status')
    elseif event_type == EventType.REPEAT_STARTED then
        assert(payload.repeat_index > 0 and payload.repeat_count > 0 and
            payload.repeat_index <= payload.repeat_count,
            'event payload repeat.started has invalid repeat bounds')
    elseif event_type == EventType.REPEAT_FINISHED then
        assert(payload.repeat_index > 0,
            'event payload repeat.finished has invalid repeat index')
    elseif event_type == EventType.SUITE_FINISHED then
        validate_counts(payload.behavior_summary,
            'event payload suite.finished.behavior_summary')
    elseif event_type == EventType.SCHEDULER_BLOCKED and
            payload.kind ~= nil then
        assert(payload.kind == SchedulerFailureKind.EXECUTOR_QUARANTINED or
            payload.kind == SchedulerFailureKind.ACTIVATION_INVALID,
            'event payload scheduler.blocked has invalid scheduler kind')
        if payload.kind == SchedulerFailureKind.EXECUTOR_QUARANTINED then
            assert(type(payload.blocking_run_id) == 'string' and
                payload.blocking_run_id ~= '',
                'event payload scheduler.blocked requires blocking run id')
            assert(is_nonnegative_integer(payload.blocking_generation) and
                payload.blocking_generation > 0,
                'event payload scheduler.blocked requires blocking generation')
        end
    elseif event_type == EventType.COMMAND_STAGE then
        assert(COMMAND_STAGES[payload.stage] == true,
            'event payload command.stage has invalid stage')
        assert(COMMAND_STAGE_STATUSES[payload.stage][payload.status] == true,
            'event payload command.stage has invalid status')
        assert(payload.attempt > 0,
            'event payload command.stage has invalid attempt')
        assert(payload.configured_timeout_ms > 0,
            'event payload command.stage has invalid configured timeout')
        if payload.operation_key ~= nil then
            assert(type(payload.operation_key) == 'string' and
                payload.operation_key ~= '',
                'event payload command.stage has invalid operation key')
        end
        if payload.subject_identity ~= nil then
            assert(type(payload.subject_identity) == 'string' and
                payload.subject_identity ~= '',
                'event payload command.stage has invalid subject identity')
        end
        if payload.evidence_kind ~= nil then
            assert(payload.stage == 'completion' and
                TERMINAL_EVIDENCE_KINDS[payload.evidence_kind] == true,
                'event payload command.stage has invalid evidence kind')
        end
        require('dwarfspec.protocol.verified_execution_schemas').new()
            :validate_command_identity(payload.command)
    elseif event_type == EventType.COMMAND_STARTED or
            event_type == EventType.COMMAND_FINISHED then
        if payload.command ~= nil then
            require('dwarfspec.protocol.verified_execution_schemas').new()
                :validate_command_identity(payload.command)
        end
        if payload.evidence_kind ~= nil then
            assert(TERMINAL_EVIDENCE_KINDS[payload.evidence_kind] == true,
                'event payload command.finished has invalid evidence kind')
        end
        if event_type == EventType.COMMAND_FINISHED then
            if payload.attempt_count ~= nil then
                assert(is_positive_integer(payload.attempt_count),
                    'event payload command.finished has invalid attempt count')
            end
            if payload.configured_timeout_ms ~= nil then
                assert(is_positive_integer(payload.configured_timeout_ms),
                    'event payload command.finished has invalid configured timeout')
            end
        end
    end
    if event_type == EventType.PROBLEM_RECORDED then
        M.validate_problem(payload, 'event payload problem.recorded')
    elseif event_type == EventType.DIAGNOSTIC_RECORDED and
            (payload.kind == focus_diagnostics.CHANGE_KIND or
                payload.kind == focus_diagnostics.INCOMPLETE_KIND) then
        focus_diagnostics.validate(
            payload, 'event payload diagnostic.recorded')
    end
    if event_type == EventType.CLEANUP_TRANSACTION_REGISTERED or
            event_type == EventType.CLEANUP_TRANSACTION_STARTED or
            event_type == EventType.CLEANUP_TRANSACTION_FINISHED or
            event_type == EventType.CLEANUP_TRANSACTION_ABANDONED then
        require('dwarfspec.protocol.verified_execution_schemas').new()
            :validate_cleanup_event(payload.cleanup_event)
    end
    if event_type == EventType.REPEAT_FINISHED then
        validate_counts(payload.counts,
            'event payload repeat.finished.counts')
    elseif event_type == EventType.RUN_FINISHED then
        validate_counts(payload.totals,
            'event payload run.finished.totals')
    end
end

---Validates one complete structured event envelope.
---@param event table
---@param expected table|nil
---@return table
function M.validate(event, expected)
    assert(type(event) == 'table', 'automation event must be a table')
    assert(event.schema == M.schema,
        'unsupported automation event schema: ' .. tostring(event.schema))
    for _, field in ipairs({
            'service_instance_id', 'project_id', 'run_id', 'type'}) do
        assert(type(event[field]) == 'string' and event[field] ~= '',
            'automation event has invalid field: ' .. field)
    end
    assert(is_nonnegative_integer(event.generation) and
        event.generation > 0,
        'automation event generation must be a positive integer')
    assert(is_nonnegative_integer(event.sequence) and event.sequence > 0,
        'automation event sequence must be a positive integer')
    assert(is_nonnegative_integer(event.elapsed_ms),
        'automation event elapsed time must be a nonnegative integer')
    M.validate_payload(event.type, event.payload)

    for _, field in ipairs({
            'service_instance_id', 'project_id', 'run_id', 'generation'}) do
        if expected and expected[field] ~= nil then
            assert(event[field] == expected[field],
                'automation event identity mismatch: ' .. field)
        end
    end
    M.copy_json(event, 'automation event')
    return event
end

---Creates an empty service-owned event journal for one admitted run.
---@param identity table
---@return table
function M.new_journal(identity)
    assert(type(identity) == 'table',
        'event journal identity must be a table')
    local journal = {
        service_instance_id=identity.service_instance_id,
        project_id=identity.project_id,
        run_id=identity.run_id,
        generation=identity.generation,
        admitted_at_ms=identity.admitted_at_ms,
        events={},
    }
    for _, field in ipairs({
            'service_instance_id', 'project_id', 'run_id'}) do
        assert(type(journal[field]) == 'string' and journal[field] ~= '',
            'event journal has invalid identity field: ' .. field)
    end
    assert(is_nonnegative_integer(journal.generation) and
        journal.generation > 0,
        'event journal generation must be a positive integer')
    assert(is_nonnegative_integer(journal.admitted_at_ms),
        'event journal admission time must be a nonnegative integer')
    return journal
end

---Appends one immutable event and returns a detached observation.
---@param journal table
---@param event_type DwarfSpecEventType
---@param payload table
---@param timestamp_ms integer
---@return table
function M.publish(journal, event_type, payload, timestamp_ms)
    assert(type(journal) == 'table' and type(journal.events) == 'table',
        'automation event journal is invalid')
    assert(is_nonnegative_integer(timestamp_ms),
        'event timestamp must be a nonnegative integer')
    assert(timestamp_ms >= journal.admitted_at_ms,
        'event timestamp precedes run admission')
    M.validate_payload(event_type, payload)

    local event = {
        schema=M.schema,
        service_instance_id=journal.service_instance_id,
        project_id=journal.project_id,
        run_id=journal.run_id,
        generation=journal.generation,
        sequence=#journal.events + 1,
        type=event_type,
        elapsed_ms=timestamp_ms - journal.admitted_at_ms,
        payload=M.copy_json(payload, 'event payload'),
    }
    M.validate(event, journal)
    table.insert(journal.events, event)
    return M.copy_json(event, 'published event')
end

---Validates contiguous journal ordering and immutable run identity.
---@param journal table
---@return table
function M.validate_journal(journal)
    assert(type(journal) == 'table' and type(journal.events) == 'table',
        'automation event journal is invalid')
    local kind = container_kind(journal.events, 'automation event journal')
    assert(kind == 'array' or next(journal.events) == nil,
        'automation event journal must be a dense array')
    local command_identities = {}
    local cleanup_transactions = {}
    for index, event in ipairs(journal.events) do
        M.validate(event, journal)
        assert(event.sequence == index,
            ('automation event sequence discontinuity: expected %d, found %s')
                :format(index, tostring(event.sequence)))
        local payload = event.payload
        if event.type == EventType.CLEANUP_TRANSACTION_REGISTERED then
            cleanup_transactions[payload.cleanup_event.transaction_id] =
                payload.cleanup_event
        end
        local command = payload.command
        if command ~= nil then
            assert(command.service_run_id == journal.run_id,
                'command event journal has a foreign service run owner')
            local known = command_identities[command.invocation_id]
            if known ~= nil then
                for _, field in ipairs({'root_invocation_id', 'owner_scope',
                        'service_run_id', 'suite_execution_id',
                        'test_attempt_id', 'repeat_index',
                        'spec_file_identity', 'test_identity',
                        'parent_invocation_id',
                        'parent_cleanup_transaction_id'}) do
                    assert(known[field] == command[field],
                        'command event journal identity mismatch: ' .. field)
                end
            else
                if command.parent_invocation_id ~= nil then
                    local parent = command_identities[command.parent_invocation_id]
                    assert(parent ~= nil,
                        'command event journal has an unknown parent invocation')
                    assert(parent.root_invocation_id == command.root_invocation_id and
                        parent.owner_scope == command.owner_scope and
                        parent.service_run_id == command.service_run_id and
                        parent.suite_execution_id == command.suite_execution_id and
                        parent.test_attempt_id == command.test_attempt_id and
                        parent.repeat_index == command.repeat_index and
                        parent.spec_file_identity == command.spec_file_identity and
                        parent.test_identity == command.test_identity,
                        'command event journal has inconsistent parent ancestry')
                elseif command.parent_cleanup_transaction_id ~= nil then
                    local transaction = cleanup_transactions[
                        command.parent_cleanup_transaction_id]
                    assert(transaction ~= nil,
                        'command event journal has an unknown cleanup parent')
                    assert(transaction.owner_scope == command.owner_scope and
                        transaction.service_run_id == command.service_run_id and
                        transaction.suite_execution_id ==
                            command.suite_execution_id and
                        transaction.test_attempt_id == command.test_attempt_id and
                        transaction.repeat_index == command.repeat_index and
                        transaction.spec_file_identity ==
                            command.spec_file_identity and
                        transaction.test_identity == command.test_identity,
                        'command event journal has inconsistent cleanup ancestry')
                end
                command_identities[command.invocation_id] = command
            end
        end
    end
    return journal
end

---Returns detached events after a stable one-based sequence cursor.
---@param journal table
---@param after_sequence integer
---@return table
function M.read(journal, after_sequence)
    M.validate_journal(journal)
    assert(is_nonnegative_integer(after_sequence),
        'event cursor must be a nonnegative integer')
    local last_sequence = #journal.events
    assert(after_sequence <= last_sequence,
        ('stale event cursor is ahead of journal: %d > %d')
            :format(after_sequence, last_sequence))

    local selected = {}
    for index = after_sequence + 1, last_sequence do
        table.insert(selected,
            M.copy_json(journal.events[index], 'event cursor result'))
    end
    return {
        events=selected,
        last_sequence=last_sequence,
    }
end

---Returns all supported initial event-type enum values in deterministic order.
---@return DwarfSpecEventType[]
function M.types()
    local result = {}
    for _, event_type in pairs(EventType) do
        table.insert(result, event_type)
    end
    table.sort(result)
    return result
end

return M
