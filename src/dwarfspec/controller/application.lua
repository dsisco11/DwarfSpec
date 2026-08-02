-- Command selection and orchestration for the external DwarfSpec process.

local command_line = require('dwarfspec.controller.command_line')
local config = require('dwarfspec.controller.configuration.config')
local dotenv = require('dwarfspec.controller.configuration.dotenv')
local project = require('dwarfspec.controller.discovery.project')
local ResultPolicy = require('dwarfspec.protocol.enums.result_policies')
local result_store = require('dwarfspec.controller.result_store')
local runner = require('dwarfspec.controller.execution.runner')
local report = require('dwarfspec.controller.reporting.report')
local glob = require('dwarfspec.support.glob')

local application = {
    version=command_line.version,
}

---Writes one line-oriented message through a caller-selected stream.
---@param stream any
---@param message string
local function write(stream, message)
    stream:write(message)
    if message:sub(-1) ~= '\n' then stream:write('\n') end
end

---Removes an incidental Lua source location from a command diagnostic.
---@param value any
---@return string
local function clean_message(value)
    return tostring(value):gsub('^.-:%d+: ', '')
end

---Resolves the project root and overlays its optional dotenv configuration.
---@param options table
---@param context table
---@return table
local function resolve_project_environment(options, context)
    local filesystem = context.filesystem or project.filesystem()
    options.filesystem = filesystem
    options.project_root = project.resolve_root(options.project_root,
        context.current_directory or filesystem.currentdir(), filesystem)
    options.result_policy = options.result_path == false and
        ResultPolicy.NONE or ResultPolicy.FILE
    options.result_path = result_store.resolve_path(options.project_root,
        options.result_path, filesystem)
    local environment = context.environment or {getenv=os.getenv}
    local dotenv_values = dotenv.load(project.join(options.project_root,
        '.env'), filesystem, context.readfile)
    local process_runner = environment.getenv('DFHACK_RUNNER')
    local process_root = environment.getenv('DFHACK_ROOT')
    if (process_runner ~= nil and process_runner ~= '') or
            (process_root ~= nil and process_root ~= '') then
        dotenv_values.DFHACK_RUNNER = nil
        dotenv_values.DFHACK_ROOT = nil
    end
    options.environment = dotenv.overlay(environment, dotenv_values)
    return filesystem
end

---Discovers and optionally filters canonical identities for list or run.
---@param options table
---@param expression string|nil
---@param context table
---@return string[]
local function select_identities(options, expression, context)
    local filesystem = resolve_project_environment(options, context)
    local project_config = config.load(options.project_root, filesystem,
        context.loadfile)
    options.error_format = project_config.settings.error_format
    options.test_glob = options.test_glob or
        options.environment.getenv('DWARFSPEC_TEST_GLOB') or
        project_config.settings.discovery.test_glob
    local identities = project.discover(options.project_root, filesystem,
        options.test_glob)
    local selected = glob.select(identities, expression)
    assert(#selected > 0, expression and
        ('glob matched no DwarfSpec tests: ' .. expression) or
        'project contains no DwarfSpec tests')
    return selected
end

---Adds shared transport dependencies and an output emitter to runner options.
---@param options table
---@param context table
---@param output any
local function prepare_runner_options(options, context, output)
    options.host_scripts = context.host_scripts
    options.invoke = context.invoke
    options.decode_json = context.decode_json
    options.emit = function(line) write(output, line) end
end

---Writes a runner failure when one is present and returns its exit code.
---@param outcome table
---@param errors any
---@return integer
local function finish(outcome, errors)
    if outcome.error then write(errors, outcome.error.message) end
    return outcome.exit_code
end

---Runs a parsed command request through discovery and controller services.
---@param request table
---@param context table
---@param output any
---@param errors any
---@return integer
local function dispatch(request, context, output, errors)
    local command = request.command
    if command == 'help' then
        write(output, command_line.help(request.topic))
        return 0
    end
    if command == 'version' then
        write(output, 'DwarfSpec ' .. application.version)
        return 0
    end
    if command == 'list' then
        local selected = select_identities(request.options, request.selection,
            context)
        for _, identity in ipairs(selected) do write(output, identity) end
        return 0
    end

    local controller = context.runner or runner
    local options = request.options
    if command == 'run' then
        options.identities = select_identities(options, request.selection,
            context)
        prepare_runner_options(options, context, output)
        options.system = context.system
        options.now = context.now
        options.sleep = context.sleep
        return finish(controller.run(options), errors)
    end

    resolve_project_environment(options, context)
    prepare_runner_options(options, context, output)
    if command == 'status' then
        local outcome = controller.status(options)
        if outcome.status then
            for _, line in ipairs(report.format_status(outcome.status)) do
                write(output, line)
            end
        end
        return finish(outcome, errors)
    end
    if command == 'history' then
        local outcome = controller.history(options)
        if outcome.history then
            for _, line in ipairs(report.format_run_history(outcome.history)) do
                write(output, line)
            end
        end
        return finish(outcome, errors)
    end
    if command == 'show' then
        local outcome = controller.inspect(options, request.run_id)
        if outcome.inspection and outcome.inspection.found then
            for _, line in ipairs(
                    report.format_run_inspection(outcome.inspection)) do
                write(output, line)
            end
        end
        return finish(outcome, errors)
    end
    if command == 'logs' then
        local outcome = controller.logs(options, request.run_id)
        if outcome.logs and outcome.logs.found then
            for _, line in ipairs(outcome.logs.lines) do write(output, line) end
        end
        return finish(outcome, errors)
    end
    if command == 'abort' then
        return finish(controller.abort(options, request.run_id), errors)
    end
    local outcome = controller.recover_executor(options, request.run_id,
        options.generation, options.reason)
    if outcome.scheduler then
        for _, line in ipairs(report.format_scheduler(outcome.scheduler)) do
            write(output, line)
        end
    end
    return finish(outcome, errors)
end

---Returns whether a normalized diagnostic represents invalid CLI usage.
---@param message string
---@return boolean
local function is_usage_error(message)
    return message:match('command syntax:') ~= nil or
        message:match('malformed glob:') ~= nil or
        message:match('unknown option:') ~= nil or
        message:match('accepts at most') ~= nil or
        message:match('requires') ~= nil or
        message:match('does not accept') ~= nil or
        message:match('must be') ~= nil or
        message:match('must not') ~= nil or
        message:match('contains unsupported') ~= nil or
        message:match('unknown command:') ~= nil or
        message:match('unknown help topic:') ~= nil
end

---Runs the DwarfSpec application and returns its process exit code.
---@param argv string[]
---@param context table|nil
---@return integer
function application.main(argv, context)
    context = context or {}
    local output = context.output or io.stdout
    local errors = context.errors or io.stderr
    local package_root = assert(context.package_root,
        'DwarfSpec package root was not provided')
    local ok, result = xpcall(function()
        local parser = context.command_line or command_line
        return dispatch(parser.parse(argv, package_root), context, output,
            errors)
    end, function(value) return value end)
    if ok then return result end
    local message = clean_message(type(result) == 'table' and
        result.message or result)
    write(errors, message)
    if is_usage_error(message) then
        return runner.exit_codes[runner.failure_kinds.USAGE]
    end
    return runner.exit_codes[runner.failure_kinds.DEPENDENCY]
end

return application
