-- Controller transport invocation and canonical report parsing.

local process = require('dwarfspec.controller.execution.process')
local reports = require('dwarfspec.controller.reporting.report')

local M = {}
local PROBE_MARKER = 'DWARFSPEC_PROBE'
local EXPECTED_PROTOCOL = 2
local MAX_OUTPUT_LINES = 8
local MAX_LINE_BYTES = 512
local MAX_OUTPUT_BYTES = 2048
local LINE_TRUNCATED = '...<line truncated>'
local OUTPUT_TRUNCATED = '<output truncated> '

---Converts an arbitrary captured value without allowing tostring errors to escape.
---@param value any
---@return string
local function safe_tostring(value)
    local ok, rendered = pcall(tostring, value)
    if not ok or type(rendered) ~= 'string' then return '<unprintable output>' end
    return rendered
end

---Returns the longest prefix within the byte limit without splitting valid UTF-8.
---@param value string
---@param limit integer
---@return string
local function utf8_prefix(value, limit)
    if #value <= limit then return value end
    local finish = limit
    while finish > 0 do
        local next_byte = value:byte(finish + 1)
        if not next_byte or next_byte < 0x80 or next_byte > 0xbf then break end
        finish = finish - 1
    end
    return value:sub(1, finish)
end

---Returns the longest suffix within the byte limit without splitting valid UTF-8.
---@param value string
---@param limit integer
---@return string
local function utf8_suffix(value, limit)
    if #value <= limit then return value end
    local first = #value - limit + 1
    while first <= #value do
        local byte = value:byte(first)
        if not byte or byte < 0x80 or byte > 0xbf then break end
        first = first + 1
    end
    return value:sub(first)
end

---Collects captured output in deterministic numeric-index order.
---@param lines any
---@return any[]
local function ordered_output(lines)
    if lines == nil then return {} end
    if type(lines) ~= 'table' then return {lines} end
    local indexes = {}
    local index = next(lines)
    while index ~= nil do
        if type(index) == 'number' and index >= 1 and index % 1 == 0 then
            indexes[#indexes + 1] = index
        end
        index = next(lines, index)
    end
    table.sort(indexes)
    local ordered = {}
    for _, numeric_index in ipairs(indexes) do
        ordered[#ordered + 1] = lines[numeric_index]
    end
    return ordered
end

---Normalizes and bounds one captured output line.
---@param value any
---@return string|nil
local function format_output_line(value)
    local rendered = safe_tostring(value):gsub('\t', ' '):gsub('[%z\1-\31\127]', '?')
    rendered = rendered:gsub('^ +', ''):gsub(' +$', '')
    if rendered == '' then return nil end
    if #rendered > MAX_LINE_BYTES then
        rendered = utf8_prefix(rendered, MAX_LINE_BYTES - #LINE_TRUNCATED) ..
            LINE_TRUNCATED
    end
    return rendered
end

---Formats recent merged subprocess output within deterministic byte and line limits.
---@param lines any
---@return string
local function format_output(lines)
    local formatted = {}
    for _, value in ipairs(ordered_output(lines)) do
        local line = format_output_line(value)
        if line then formatted[#formatted + 1] = line end
    end
    if #formatted == 0 then return '<no output>' end

    local retained = {}
    local first = math.max(1, #formatted - MAX_OUTPUT_LINES + 1)
    if first > 1 then
        retained[#retained + 1] =
            ('<%d earlier lines omitted>'):format(first - 1)
    end
    for index = first, #formatted do
        retained[#retained + 1] = formatted[index]
    end

    local output = table.concat(retained, ' | ')
    if #output > MAX_OUTPUT_BYTES then
        output = OUTPUT_TRUNCATED .. utf8_suffix(output,
            MAX_OUTPUT_BYTES - #OUTPUT_TRUNCATED)
    end
    return output
end

---Returns a validated canonical adapter error from subprocess output, if any.
---@param result table
---@param expected table|nil
---@param decoder function|nil
---@return table|nil
local function adapter_error_from_result(result, expected, decoder)
    local parsed, _, _, adapter_error = pcall(
        reports.parse_transport_response, result.lines, expected or {}, decoder)
    if parsed then return adapter_error end
    return nil
end

---Builds one bounded fallback for a nonzero subprocess result.
---@param operation string
---@param result table
---@return string
local function nonzero_message(operation, result)
    return ('DwarfSpec %s exited with %s. Output: %s'):format(
        operation, safe_tostring(result.exit_code), format_output(result.lines))
end

---Finds exact probe marker lines without treating embedded marker text as a report.
---@param lines any
---@return string[]
local function probe_candidates(lines)
    local candidates = {}
    for _, value in ipairs(ordered_output(lines)) do
        local line = safe_tostring(value)
        if line == PROBE_MARKER or
                line:sub(1, #PROBE_MARKER + 1) == PROBE_MARKER .. ' ' then
            candidates[#candidates + 1] = line
        end
    end
    return candidates
end

---Parses one exact probe report according to the controller probe grammar.
---@param line string
---@return table|nil, string|nil
local function parse_probe(line)
    local fields = {}
    local remainder = line:sub(#PROBE_MARKER + 2)
    for token in remainder:gmatch('[^ ]+') do
        local name, value = token:match('^([^=]+)=([^=]*)$')
        if not name then
            return nil, 'invalid token: ' .. safe_tostring(token)
        end
        if not name:match('^[a-z][a-z0-9_]*$') then
            return nil, 'invalid field name: ' .. safe_tostring(name)
        end
        if value == '' then return nil, 'empty value for field ' .. name end
        if not value:match('^[A-Za-z0-9._+%-]+$') then
            return nil, ('invalid value for field %s: %s'):format(
                name, safe_tostring(value))
        end
        if fields[name] ~= nil then return nil, 'duplicate field: ' .. name end
        fields[name] = value
    end

    for _, name in ipairs({'protocol', 'core', 'timeout'}) do
        if fields[name] == nil then
            return nil, 'missing required field: ' .. name
        end
    end
    if not fields.protocol:match('^[1-9][0-9]*$') then
        return nil, 'invalid protocol value: ' .. fields.protocol
    end
    if fields.core ~= 'true' and fields.core ~= 'false' and
            fields.core ~= 'unavailable' then
        return nil, 'invalid core value: ' .. fields.core
    end
    local timeout_values = {
        ['nil']=true, boolean=true, number=true, string=true, ['function']=true,
        userdata=true, thread=true, table=true, unavailable=true,
    }
    if not timeout_values[fields.timeout] then
        return nil, 'invalid timeout value: ' .. fields.timeout
    end
    return fields, nil
end

---Creates a transport client over the subprocess and report authorities.
---@param dependencies table
---@return table
function M.new(dependencies)
    assert(type(dependencies) == 'table', 'transport client dependencies are required')
    local builder = assert(dependencies.builder, 'transport command builder is required')
    local failure = assert(dependencies.failure, 'transport failure constructor is required')
    local kinds = assert(dependencies.failure_kinds, 'transport failure kinds are required')
    local clean_message = assert(dependencies.clean_message, 'transport error cleaner is required')
    local client = {}

    ---Resolves the configured dfhack-run executable.
    ---@param options table
    ---@return string|nil, table|nil
    function client.resolve(options)
        local ok, runner = pcall(process.resolve_runner, options, options.environment)
        if ok then return runner, nil end
        return nil, failure(kinds.DEPENDENCY, clean_message(runner))
    end

    ---Verifies a healthy DFHack core context.
    ---@param options table
    ---@param runner string
    function client.verify_connection(options, runner)
        local invoke = options.invoke or process.invoke
        local ok, result = pcall(invoke, runner, builder.probe(options))
        if not ok then
            error(failure(kinds.CONNECTION,
                ('Could not invoke DFHack runner "%s": %s'):format(
                    runner, clean_message(result))), 0)
        end
        if result.exit_code ~= 0 then
            error(failure(kinds.CONNECTION,
                ('DFHack connection probe through "%s" exited with code %s. ' ..
                    'Output: %s'):format(runner, safe_tostring(result.exit_code),
                    format_output(result.lines))), 0)
        end

        local candidates = probe_candidates(result.lines)
        if #candidates == 0 then
            error(failure(kinds.CONNECTION,
                ('DFHack responded through "%s", but emitted no DwarfSpec ' ..
                    'probe report. Output: %s'):format(
                    runner, format_output(result.lines))), 0)
        end
        if #candidates > 1 then
            error(failure(kinds.CONNECTION,
                ('DFHack emitted %d DwarfSpec probe reports; expected exactly ' ..
                    'one. Output: %s'):format(
                    #candidates, format_output(result.lines))), 0)
        end

        local probe, reason = parse_probe(candidates[1])
        if not probe then
            error(failure(kinds.CONNECTION,
                ('DFHack emitted a malformed DwarfSpec probe report: %s. ' ..
                    'Probe: %s'):format(format_output({reason}),
                    format_output({candidates[1]}))), 0)
        end
        if probe.protocol ~= tostring(EXPECTED_PROTOCOL) then
            error(failure(kinds.CONNECTION,
                ('DwarfSpec protocol mismatch: controller expects %d, probe ' ..
                    'reported %s. Check for mixed installed DwarfSpec package ' ..
                    'versions.'):format(EXPECTED_PROTOCOL, probe.protocol)), 0)
        end
        if probe.core ~= 'true' then
            error(failure(kinds.CONNECTION,
                ('DFHack probe did not run in a healthy core Lua context: ' ..
                    'expected core=true, reported core=%s.'):format(
                    probe.core)), 0)
        end
        if probe.timeout ~= 'function' then
            error(failure(kinds.CONNECTION,
                ('DFHack core Lua context is missing the required ' ..
                    'dfhack.timeout function: reported timeout=%s.'):format(
                    probe.timeout)), 0)
        end
    end

    ---Invokes one command and returns its raw subprocess result.
    ---@param options table
    ---@param runner string
    ---@param arguments string[]
    ---@return table
    function client.invoke(options, runner, arguments)
        return (options.invoke or process.invoke)(runner, arguments)
    end

    ---Invokes and parses one canonical transport envelope.
    ---@param options table
    ---@param runner string
    ---@param arguments string[]
    ---@param expected table
    ---@param operation string
    ---@return table
    function client.transport(options, runner, arguments, expected, operation)
        local invoked, result = pcall(client.invoke, options, runner, arguments)
        if not invoked then
            error(failure(kinds.HOST,
                ('DwarfSpec %s bridge failed: %s'):format(
                    operation, clean_message(result))), 0)
        end
        if result.exit_code ~= 0 then
            local adapter_error = adapter_error_from_result(
                result, expected, options.decode_json)
            if adapter_error then error(adapter_error, 0) end
            error(failure(kinds.HOST, nonzero_message(operation, result)), 0)
        end
        return reports.parse_transport(result.lines, expected, options.decode_json)
    end

    ---Invokes and parses a bootstrap response that may contain a rejection.
    ---@param options table
    ---@param runner string
    ---@param arguments string[]
    ---@param expected table
    ---@return table|nil, string|nil, table|nil
    function client.bootstrap_response(options, runner, arguments, expected)
        local invoked, result = pcall(client.invoke, options, runner, arguments)
        if not invoked then
            local detail = failure(kinds.REGISTRATION,
                'DwarfSpec bootstrap bridge failed: ' .. clean_message(result))
            detail.retryable = true
            error(detail, 0)
        end
        if result.exit_code ~= 0 then
            local adapter_error = adapter_error_from_result(
                result, expected, options.decode_json)
            if adapter_error then return nil, nil, adapter_error end
            error(failure(kinds.REGISTRATION,
                nonzero_message('bootstrap', result)), 0)
        end
        local transport, _, adapter_error = reports.parse_transport_response(
            result.lines, expected, options.decode_json)
        if adapter_error then return nil, nil, adapter_error end
        return transport, reports.owner_capability(result.lines), nil
    end

    ---Parses one scheduler status response.
    ---@param options table
    ---@param runner string
    ---@return table
    function client.scheduler_status(options, runner)
        local invoked, result = pcall(client.invoke, options, runner,
            builder.scheduler_status(options))
        if not invoked then
            error(failure(kinds.HOST,
                'DwarfSpec status bridge failed: ' .. clean_message(result)), 0)
        end
        if result.exit_code ~= 0 then
            local adapter_error = adapter_error_from_result(
                result, nil, options.decode_json)
            if adapter_error then error(adapter_error, 0) end
            error(failure(kinds.HOST, nonzero_message('status', result)), 0)
        end
        return reports.parse_status(result.lines, options.decode_json)
    end

    ---Invokes and parses one retained-run query response.
    ---@param options table
    ---@param runner string
    ---@param operation string
    ---@param run_id string|nil
    ---@return table
    function client.query(options, runner, operation, run_id)
        local invoked, result = pcall(client.invoke, options, runner,
            builder.query(options, operation, run_id))
        if not invoked then
            error(failure(kinds.HOST,
                ('DwarfSpec %s query bridge failed: %s'):format(
                    operation, clean_message(result))), 0)
        end
        if result.exit_code ~= 0 then
            local adapter_error = adapter_error_from_result(
                result, nil, options.decode_json)
            if adapter_error then error(adapter_error, 0) end
            error(failure(kinds.HOST,
                nonzero_message(operation .. ' query', result)), 0)
        end
        local parsers = {
            history=reports.parse_run_history,
            show=reports.parse_run_inspection,
            logs=reports.parse_run_logs,
        }
        return assert(parsers[operation],
            'unsupported retained-run query: ' .. tostring(operation))(
                result.lines, options.decode_json)
    end

    ---Parses a raw canonical transport result for recovery workflows.
    ---@param lines string[]
    ---@param expected table
    ---@param decoder function|nil
    ---@return table
    function client.parse_transport(lines, expected, decoder)
        return reports.parse_transport(lines, expected, decoder)
    end

    ---Returns the report authority's event formatter for polling composition.
    ---@return function
    function client.event_formatter()
        return reports.format_events
    end

    return client
end

return M
