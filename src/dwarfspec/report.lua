-- Native-host JSON report parsing, validation, and result-file persistence.

local M = {}
local events = require('dwarfspec.automation.events')
local schemas = require('dwarfspec.automation.schemas')
local RunState = require('dwarfspec.automation.run_states')

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

---Returns the last machine-readable report line from process output.
---@param lines string[]
---@return string
local function report_line(lines)
    local found
    for _, line in ipairs(lines) do
        if line:sub(1, #PREFIX) == PREFIX then found = line end
    end
    assert(found, 'DFHack output did not contain a DWARFSPEC_JSON report')
    return found
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
    error('unsupported DwarfSpec report schema: ' ..
        tostring(report.schema), 0)
end

---Decodes and validates one native DwarfSpec report.
---@param lines string[]
---@param expected table|string|nil
---@param decoder function|nil
---@return table, string
function M.parse(lines, expected, decoder)
    local line = report_line(lines)
    local payload = line:sub(#PREFIX + 1)
    local decode = decoder or function(text)
        return require('dkjson').decode(text, 1, nil)
    end
    local report, _, decode_error = decode(payload)
    assert(report, 'DFHack emitted invalid DwarfSpec JSON: ' ..
        tostring(decode_error))
    return M.validate(report, expected), payload
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

return M
