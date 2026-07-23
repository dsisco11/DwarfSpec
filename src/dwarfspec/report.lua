-- Native-host JSON report parsing, validation, and result-file persistence.

local M = {}
local events = require('dwarfspec.automation.events')
local EventType = require('dwarfspec.automation.event_types')
local schemas = require('dwarfspec.automation.schemas')
local RunState = require('dwarfspec.automation.run_states')
local SchedulerFailureKind =
    require('dwarfspec.automation.scheduler_failure_kinds')
local RunnerFailureKind = require('dwarfspec.runner_failure_kinds')

local PREFIX = 'DWARFSPEC_JSON '
local OWNER_PREFIX = 'DWARFSPEC_OWNER '

local RUN_STATE_TERMINAL = {
    [RunState.QUEUED]=false,
    [RunState.STARTING]=false,
    [RunState.RUNNING]=false,
    [RunState.CLEANING]=false,
    [RunState.PASSED]=true,
    [RunState.FAILED]=true,
    [RunState.ABORTED]=true,
    [RunState.CANCELLED]=true,
}

---Validates one canonical adapter error response.
---@param report table
---@return table
local function validate_error(report)
    events.copy_json(report, 'adapter error response')
    assert(report.protocol == 2,
        'unsupported DwarfSpec protocol: ' .. tostring(report.protocol))
    assert(report.kind == RunnerFailureKind.REGISTRATION,
        'unsupported DwarfSpec adapter error kind: ' .. tostring(report.kind))
    assert(type(report.message) == 'string' and report.message ~= '',
        'DwarfSpec adapter error message must be a non-empty string')
    return report
end

---Validates one transitional version 1 native report.
---@param report table
---@param expected table
---@return table
local function validate_version_one(report, expected)
    events.copy_json(report, 'version 1 report')
    for _, field in ipairs({
            'schema', 'protocol', 'run_id', 'state', 'terminal', 'generation',
            'counts', 'totals', 'output_count', 'cleanup_confirmed',
            'failures'}) do
        assert(report[field] ~= nil,
            'DwarfSpec JSON report is missing field: ' .. field)
    end
    assert(report.protocol == 1,
        'unsupported DwarfSpec protocol: ' .. tostring(report.protocol))
    local terminal = RUN_STATE_TERMINAL[report.state]
    assert(terminal ~= nil,
        'unsupported DwarfSpec run state: ' .. tostring(report.state))
    assert(report.terminal == terminal,
        'DwarfSpec terminal flag does not match run state')
    if expected.run_id ~= nil then
        assert(report.run_id == expected.run_id,
            ('DwarfSpec report run id %q does not match %q')
                :format(tostring(report.run_id), expected.run_id))
    end
    return report
end

---Returns every machine-readable report payload in output order.
---@param lines string[]
---@return string[]
local function report_payloads(lines)
    local payloads = {}
    for _, line in ipairs(lines) do
        if line:sub(1, #PREFIX) == PREFIX then
            table.insert(payloads, line:sub(#PREFIX + 1))
        end
    end
    assert(#payloads > 0,
        'DFHack output did not contain a DWARFSPEC_JSON report')
    return payloads
end

---Returns the sole canonical machine-readable payload from process output.
---@param lines string[]
---@return string
local function report_line(lines)
    local payloads = report_payloads(lines)
    assert(#payloads == 1,
        ('DFHack output contained %d DWARFSPEC_JSON reports; expected one')
            :format(#payloads))
    return payloads[1]
end

---Returns the one bootstrap-only owner capability from process output.
---@param lines string[]
---@return string
function M.owner_capability(lines)
    local found
    for _, line in ipairs(lines) do
        if line:sub(1, #OWNER_PREFIX) == OWNER_PREFIX then
            assert(found == nil,
                'DFHack output contained multiple owner capabilities')
            found = line:sub(#OWNER_PREFIX + 1)
        end
    end
    assert(type(found) == 'string' and #found >= 32 and #found <= 512,
        'DFHack output did not contain a valid owner capability')
    return found
end

---Validates one supported native or service transport report.
---@param report table
---@param expected table|string|nil
---@return table
function M.validate(report, expected)
    assert(type(report) == 'table', 'DwarfSpec JSON report must be a table')
    if type(expected) == 'string' then expected = {run_id=expected} end
    expected = expected or {}
    if report.schema == 'dwarfspec.run.v1' then
        return validate_version_one(report, expected)
    end
    if report.schema == 'dwarfspec.transport.v2' then
        return schemas.validate_transport(report, expected)
    end
    if report.schema == 'dwarfspec.error.v1' then
        return validate_error(report)
    end
    error('unsupported DwarfSpec report schema: ' ..
        tostring(report.schema), 0)
end

---Decodes and validates one native DwarfSpec report.
---@param lines string[]
---@param expected table|string|nil
---@param decoder function|nil
---@return table, string
function M.parse(lines, expected, decoder)
    local payload = report_line(lines)
    local decode = decoder or function(text)
        return require('dkjson').decode(text, 1, nil)
    end
    local report, _, decode_error = decode(payload)
    assert(report, 'DFHack emitted invalid DwarfSpec JSON: ' ..
        tostring(decode_error))
    return M.validate(report, expected), payload
end

---Decodes either a version 2 transport or a canonical adapter error.
---@param lines string[]
---@param expected table
---@param decoder function|nil
---@return table|nil, string, table|nil
function M.parse_transport_response(lines, expected, decoder)
    local report, payload = M.parse(lines, expected, decoder)
    if report.schema == 'dwarfspec.error.v1' then
        return nil, payload, report
    end
    assert(report.schema == 'dwarfspec.transport.v2',
        'DFHack output did not contain version 2 transport data')
    return report, payload, nil
end

---Decodes and validates exactly one canonical version 2 transport response.
---@param lines string[]
---@param expected table
---@param decoder function|nil
---@return table, string
function M.parse_transport(lines, expected, decoder)
    local transport, payload, response_error =
        M.parse_transport_response(lines, expected, decoder)
    assert(response_error == nil, response_error and response_error.message)
    return transport, payload
end

---Decodes every native DwarfSpec report in transport order.
---@param lines string[]
---@param expected table|string|nil
---@param decoder function|nil
---@return table[]
function M.parse_all(lines, expected, decoder)
    local decode = decoder or function(text)
        return require('dkjson').decode(text, 1, nil)
    end
    local parsed = {}
    for _, payload in ipairs(report_payloads(lines)) do
        local report, _, decode_error = decode(payload)
        assert(report, 'DFHack emitted invalid DwarfSpec JSON: ' ..
            tostring(decode_error))
        table.insert(parsed, {
            report=M.validate(report, expected),
            payload=payload,
        })
    end
    return parsed
end

---Validates one version 2 persisted result document.
---@param result table
---@return table
function M.validate_result(result)
    return schemas.validate_result(result)
end

---Returns newly streamed Busted output lines without protocol framing.
---@param lines string[]
---@return string[]
function M.progress(lines)
    local progress = {}
    for _, line in ipairs(lines) do
        local _, _, text = line:find('^OUTPUT %d+ (.*)$')
        if text then table.insert(progress, text) end
    end
    return progress
end

---Formats one structured event for terminal progress output.
---@param event table
---@return string|nil
local function format_event(event)
    local payload = event.payload
    if event.type == EventType.RUN_QUEUED then
        return 'QUEUED'
    elseif event.type == EventType.RUN_ACTIVATED then
        return ('ACTIVATED after %d ms'):format(payload.queue_wait_ms)
    elseif event.type == EventType.RUN_STARTED then
        return ('RUN started (%d repeat%s)'):format(payload.repeat_count,
            payload.repeat_count == 1 and '' or 's')
    elseif event.type == EventType.REPEAT_STARTED then
        return ('RUN %d/%d'):format(payload.repeat_index,
            payload.repeat_count)
    elseif event.type == EventType.REPEAT_FINISHED then
        return ('RUN_END %d successes=%d failures=%d errors=%d pending=%d')
            :format(payload.repeat_index, payload.counts.successes,
                payload.counts.failures, payload.counts.errors,
                payload.counts.pending)
    elseif event.type == EventType.TEST_STARTED then
        return 'START ' .. payload.name
    elseif event.type == EventType.TEST_FINISHED then
        return ('%s %s (%d ms)'):format(payload.status:upper(),
            payload.name, payload.duration_ms)
    elseif event.type == EventType.PROBLEM_RECORDED then
        return ('%s %s: %s'):format(payload.kind:upper(),
            payload.name, payload.message)
    elseif event.type == EventType.CLEANUP_STARTED then
        return ('CLEANUP started (%d pending)'):format(
            payload.pending_action_count)
    elseif event.type == EventType.CLEANUP_FAILED then
        return ('CLEANUP_FAILED %s: %s'):format(payload.action_name,
            payload.message)
    elseif event.type == EventType.CLEANUP_FINISHED then
        return ('CLEANUP finished confirmed=%s'):format(
            tostring(payload.cleanup_confirmed))
    elseif event.type == EventType.RUN_CANCELLED then
        return 'CANCELLED ' .. payload.reason
    elseif event.type == EventType.RUN_ABORTED then
        return 'ABORTED ' .. payload.reason
    elseif event.type == EventType.RUN_FINISHED then
        return ('FINISHED %s cleanup_confirmed=%s'):format(
            payload.terminal_state,
            tostring(payload.cleanup_confirmed))
    elseif event.type == EventType.SCHEDULER_BLOCKED then
        if payload.kind == SchedulerFailureKind.EXECUTOR_QUARANTINED then
            return ('EXECUTOR_QUARANTINED: run %s generation %d left ' ..
                'cleanup unconfirmed: %s. This run remains queued; press ' ..
                'Ctrl+C and restart DFHack after confirming no live run is ' ..
                'active'):format(payload.blocking_run_id,
                    payload.blocking_generation, payload.reason)
        end
        return 'SCHEDULER_BLOCKED ' .. payload.reason
    end
    return nil
end

---Formats structured transport events without depending on diagnostic lines.
---@param transport_events table[]
---@return string[]
function M.format_events(transport_events)
    local lines = {}
    for _, event in ipairs(transport_events) do
        local line = format_event(event)
        if line ~= nil then table.insert(lines, line) end
    end
    return lines
end

return M
