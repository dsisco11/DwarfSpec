-- Native-host JSON report parsing, validation, and result-file persistence.

local M = {}
local events = require('dwarfspec.automation.events')
local schemas = require('dwarfspec.automation.schemas')

local PREFIX = 'DWARFSPEC_JSON '

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
    if expected.run_id ~= nil then
        assert(report.run_id == expected.run_id,
            ('DwarfSpec report run id %q does not match %q')
                :format(tostring(report.run_id), expected.run_id))
    end
    return report
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

---Writes one DFHack-encoded JSON report to a caller-selected result path.
---@param path string
---@param contents string
function M.write(path, contents)
    assert(type(contents) == 'string' and contents ~= '',
        'native JSON report was not available for persistence')
    local file, open_error = io.open(path, 'wb')
    assert(file, 'could not open result report: ' .. tostring(open_error))
    local ok, write_error = file:write(contents, '\n')
    file:close()
    assert(ok, 'could not write result report: ' .. tostring(write_error))
end

return M
