-- Controller transport invocation and canonical report parsing.

local process = require('dwarfspec.controller.execution.process')
local reports = require('dwarfspec.controller.reporting.report')

local M = {}

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
                'could not contact DFHack through ' .. runner .. ': ' ..
                    clean_message(result)), 0)
        end
        if result.exit_code ~= 0 or
                result.lines[#result.lines] ~=
                    'DWARFSPEC_PROBE protocol=2 core=true timeout=function' then
            error(failure(kinds.CONNECTION,
                'DFHack is not running or did not provide a healthy core Lua context'), 0)
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
            error(failure(kinds.HOST,
                ('DwarfSpec %s exited with %d'):format(operation, result.exit_code)), 0)
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
            error(failure(kinds.REGISTRATION,
                'DwarfSpec bootstrap exited with ' .. result.exit_code), 0)
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
            error(failure(kinds.HOST,
                'DwarfSpec status exited with ' .. result.exit_code), 0)
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
            error(failure(kinds.HOST,
                ('DwarfSpec %s query exited with %d'):format(
                    operation, result.exit_code)), 0)
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
