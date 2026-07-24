-- Command-line parsing and dispatch for the DwarfSpec executable.

local argparse = require('argparse')
local glob = require('dwarfspec.glob')
local config = require('dwarfspec.config')
local dotenv = require('dwarfspec.dotenv')
local project = require('dwarfspec.project')
local ResultPolicy = require('dwarfspec.automation.result_policies')
local result_store = require('dwarfspec.automation.result_store')
local runner = require('dwarfspec.runner')

local M = {
    version='0.2.0',
}

local HELP = [[
DwarfSpec 0.2.0 - live DFHack automation with in-process Busted

Usage:
  dwarfspec
  dwarfspec list [glob] [--project-root PATH] [--test-glob GLOB]
  dwarfspec run [glob] [options]
  dwarfspec status [--project-root PATH] [--runner PATH]
  dwarfspec history [--project-root PATH] [--runner PATH]
  dwarfspec show RUN_ID [--project-root PATH] [--runner PATH]
  dwarfspec logs RUN_ID [--project-root PATH] [--runner PATH]
  dwarfspec abort RUN_ID [--project-root PATH] [--runner PATH]
  dwarfspec recover-executor RUN_ID --generation N [options]
  dwarfspec help [command]
  dwarfspec version

Commands:
  list     List canonical live-spec identities without executing Lua files.
  run      Run all live specs or the identities selected by one glob.
  status   Show the shared executor, queue, and quarantine state.
  history  List runs retained by the current DFHack service instance.
  show     Inspect one retained run and its structured events.
  logs     Print captured output for one retained run.
  abort    Abort one active run and require confirmed cleanup.
  recover-executor
           Clear quarantine only after authoritative host verification.
  help     Show general or command-specific help.
  version  Print the DwarfSpec version.

Run `dwarfspec help run` for options and selection syntax.
]]

local LIST_HELP = [[
Usage: dwarfspec list [glob] [--project-root PATH] [--test-glob GLOB]

Lists canonical project-relative identities in deterministic lexical order.
By default, *.ds.lua files at every depth beneath tests/ are listed. Configure
settings.discovery.test_glob in tests/dwarfspec/config.lua, set
DWARFSPEC_TEST_GLOB, or use --test-glob. Test files and Busted hooks are not
loaded or executed. A valid selection glob with no matches returns nonzero.
]]

local RUN_HELP = [[
Usage: dwarfspec run [glob] [options]

Selection:
  Identities are case-sensitive project-relative paths such as
  tests/tooltip/tooltip_spec.ds.lua. * matches within one path segment, **
  crosses path separators, ? matches one non-separator character, and \
  escapes the next character. Character classes are not supported.

Options:
  --project-root PATH          Consumer project root (default: current dir)
  --test-glob GLOB             Discovery glob (default: *.ds.lua)
  --runner PATH                Explicit dfhack-run executable
  --filter TEXT                Include Busted names matching TEXT (repeatable)
  --filter-out TEXT            Exclude Busted names matching TEXT (repeatable)
  --name TEXT                  Select a Busted name (repeatable)
  --tag TAG                    Include a Busted tag (repeatable)
  --exclude-tag TAG            Exclude a Busted tag (repeatable)
  --repeat COUNT               Repeat the selected suite (default: 1)
  --timeout SECONDS            Execution timeout after activation (default: 30)
  --queue-timeout SECONDS      Maximum wait for activation, or unlimited
                               (default: unlimited)
  --poll-interval-ms MS        Status polling interval (default: 100)
  --startup-delay-frames N     Frames before starting Busted (default: 1)
  --lease-timeout-ms MS        Lost-runner lease timeout (default: 5000)
  --lease-check-frames N       Lease check interval (default: 30)
  --results PATH               Exact JSON result file; relative paths are
                               beneath the project root
                               (default: tests/.test-results/dwarfspec/results.json)
  --no-results                 Do not persist a JSON run report
  --run-id ID                  Safe explicit run identifier
  --verbose                    Print resolved runner diagnostics

Runner lookup order is --runner, DFHACK_RUNNER, DFHACK_ROOT/dfhack-run,
then PATH. Environment values already set in the process override values loaded
from PROJECT_ROOT/.env. Concurrent projects wait in one FIFO and execute one at
a time. Successful status polls renew the queue or execution lease. Queue time
does not consume --timeout. Results replace the exact configured file; no run
history is created unless the caller chooses distinct paths. --no-results
disables the write but still validates and acknowledges the terminal result.
A run returns zero only when Busted passes and cleanup is confirmed.
]]

local ABORT_HELP = [[
Usage: dwarfspec abort RUN_ID [--project-root PATH] [--runner PATH] [--verbose]

Aborts an active DwarfSpec run through dfhack-run. Success requires an aborted
native report with cleanup_confirmed=true. The project root defaults to the
current directory and supplies the optional .env runner configuration.
]]

local STATUS_HELP = [[
Usage: dwarfspec status [--project-root PATH] [--runner PATH] [--verbose]

Reads the process-wide DwarfSpec scheduler through dfhack-run without changing
service state. The output identifies the active run, queue depth, quarantine,
and the exact recovery command when recovery is required.
]]

local HISTORY_HELP = [[
Usage: dwarfspec history [--project-root PATH] [--runner PATH] [--verbose]

Lists all runs retained by the current process-wide DwarfSpec service, newest
first and across every registered project. This is in-memory session history:
it is cleared when DFHack exits and does not create persistent result files.
]]

local SHOW_HELP = [[
Usage: dwarfspec show RUN_ID [--project-root PATH] [--runner PATH] [--verbose]

Shows one immutable run snapshot followed by its structured event journal.
The read does not renew a lease, acknowledge a result, or change scheduler
state. Only runs retained by the current DFHack service instance are available.
]]

local LOGS_HELP = [[
Usage: dwarfspec logs RUN_ID [--project-root PATH] [--runner PATH] [--verbose]

Prints the captured Busted, host, and cleanup output lines for one retained run.
The output is read-only and is available only during the current DFHack service
instance.
]]

local RECOVER_EXECUTOR_HELP = [[
Usage: dwarfspec recover-executor RUN_ID --generation N [options]

Options:
  --project-root PATH  Project root used for optional .env runner configuration
  --runner PATH        Explicit dfhack-run executable
  --generation N       Exact quarantined run generation (required)
  --reason TEXT        Bounded operator reason recorded with recovery
  --verbose            Print resolved runner diagnostics

Recovery succeeds only when the local DFHack host authoritatively verifies
that the executor and DwarfSpec mount state are clean. It does not provide an
unsafe force mode.
]]

local LIST_OPTIONS = {['project-root']=true, ['test-glob']=true}
local ABORT_OPTIONS = {['project-root']=true, runner=true, verbose=true}
local STATUS_OPTIONS = {['project-root']=true, runner=true, verbose=true}
local READ_OPTIONS = {['project-root']=true, runner=true, verbose=true}
local RECOVER_EXECUTOR_OPTIONS = {
    ['project-root']=true,
    runner=true,
    generation=true,
    reason=true,
    verbose=true,
}
local RUN_OPTIONS = {
    ['project-root']=true,
    ['test-glob']=true,
    runner=true,
    filter=true,
    ['filter-out']=true,
    name=true,
    tag=true,
    ['exclude-tag']=true,
    ['repeat']=true,
    timeout=true,
    ['queue-timeout']=true,
    ['poll-interval-ms']=true,
    ['startup-delay-frames']=true,
    ['lease-timeout-ms']=true,
    ['lease-check-frames']=true,
    results=true,
    ['no-results']=true,
    ['run-id']=true,
    verbose=true,
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

---Parses a positive integer command option.
---@param name string
---@param value string
---@return integer
local function positive_integer(name, value)
    local number = tonumber(value)
    assert(number and number >= 1 and number % 1 == 0,
        '--' .. name .. ' must be a positive integer')
    return number
end

---Parses a positive numeric command option.
---@param name string
---@param value string
---@return number
local function positive_number(name, value)
    local number = tonumber(value)
    assert(number and number > 0,
        '--' .. name .. ' must be positive')
    return number
end

---Returns a new command option table with stable defaults.
---@param package_root string
---@return table
local function defaults(package_root)
    return {
        package_root=package_root,
        host_scripts=nil,
        project_root=nil,
        test_glob=nil,
        runner=nil,
        filters={},
        filter_out={},
        names={},
        tags={},
        exclude_tags={},
        repeat_count=1,
        timeout_seconds=30,
        queue_timeout_seconds=nil,
        poll_interval_ms=100,
        startup_delay_frames=1,
        lease_timeout_ms=5000,
        lease_check_frames=30,
        result_path=result_store.default_relative_path,
        run_id=nil,
        generation=nil,
        reason='local operator requested verified recovery',
        verbose=false,
    }
end

---Adds one value-taking option when it is accepted by a command.
---@param parser table
---@param allowed table
---@param name string
---@param target string
---@param multiple boolean|nil
local function add_option(parser, allowed, name, target, multiple)
    if not allowed[name] then return end
    local option = parser:option('--' .. name):target(target)
    if multiple then option:count('*') end
end

---Builds an argparse parser for one DwarfSpec command.
---@param command string
---@param allowed table
---@return table
local function command_parser(command, allowed)
    local parser = argparse('dwarfspec ' .. command)
        :add_help(false)
    parser:argument('positionals'):args('*')
    add_option(parser, allowed, 'project-root', 'project_root')
    add_option(parser, allowed, 'test-glob', 'test_glob')
    add_option(parser, allowed, 'runner', 'runner')
    add_option(parser, allowed, 'filter', 'filters', true)
    add_option(parser, allowed, 'filter-out', 'filter_out', true)
    add_option(parser, allowed, 'name', 'names', true)
    add_option(parser, allowed, 'tag', 'tags', true)
    add_option(parser, allowed, 'exclude-tag', 'exclude_tags', true)
    add_option(parser, allowed, 'repeat', 'repeat_count')
    add_option(parser, allowed, 'timeout', 'timeout_seconds')
    add_option(parser, allowed, 'queue-timeout', 'queue_timeout_seconds')
    add_option(parser, allowed, 'poll-interval-ms', 'poll_interval_ms')
    add_option(parser, allowed, 'startup-delay-frames', 'startup_delay_frames')
    add_option(parser, allowed, 'lease-timeout-ms', 'lease_timeout_ms')
    add_option(parser, allowed, 'lease-check-frames', 'lease_check_frames')
    add_option(parser, allowed, 'results', 'result_path')
    add_option(parser, allowed, 'run-id', 'run_id')
    add_option(parser, allowed, 'generation', 'generation')
    add_option(parser, allowed, 'reason', 'reason')
    if allowed['no-results'] then
        parser:flag('--no-results'):target('no_results')
    end
    if allowed.verbose then parser:flag('--verbose'):target('verbose') end
    return parser
end

---Normalizes argparse diagnostics to DwarfSpec's established CLI wording.
---@param message any
---@return string
local function parser_message(message)
    return tostring(message):gsub("^unknown option '([^']+)'",
        'unknown option: %1')
end

---Rejects an empty inline assignment before argparse normalizes it away.
---@param arguments string[]
---@param allowed table
local function reject_empty_inline_assignments(arguments, allowed)
    for _, argument in ipairs(arguments) do
        local name, value = argument:match('^%-%-([%w-]+)=(.*)$')
        if name and allowed[name] and value == '' then
            error('--' .. name .. ' must not be empty', 2)
        end
    end
end

---Rejects an empty value supplied to a value-taking command option.
---@param name string
---@param value string|string[]|nil
local function require_nonempty_option_value(name, value)
    if type(value) == 'table' then
        for _, item in ipairs(value) do
            require_nonempty_option_value(name, item)
        end
        return
    end
    assert(value == nil or value ~= '', '--' .. name .. ' must not be empty')
end

---Validates parsed command values that have DwarfSpec-specific semantics.
---@param options table
local function validate_options(options)
    for name, value in pairs({
            ['project-root']=options.project_root,
            ['test-glob']=options.test_glob,
            runner=options.runner,
            filter=options.filters,
            ['filter-out']=options.filter_out,
            name=options.names,
            tag=options.tags,
            ['exclude-tag']=options.exclude_tags,
            results=options.result_path,
            ['run-id']=options.run_id,
            reason=options.reason}) do
        require_nonempty_option_value(name, value)
    end
    if options.test_glob then glob.compile(options.test_glob) end
    if options.repeat_count then
        options.repeat_count = positive_integer('repeat', options.repeat_count)
    end
    if options.timeout_seconds then
        options.timeout_seconds = positive_number('timeout',
            options.timeout_seconds)
    end
    if options.queue_timeout_seconds then
        if options.queue_timeout_seconds == 'unlimited' then
            options.queue_timeout_seconds = nil
        else
            options.queue_timeout_seconds = positive_number('queue-timeout',
                options.queue_timeout_seconds)
        end
    end
    if options.poll_interval_ms then
        options.poll_interval_ms = positive_integer('poll-interval-ms',
            options.poll_interval_ms)
    end
    if options.startup_delay_frames then
        options.startup_delay_frames = positive_integer('startup-delay-frames',
            options.startup_delay_frames)
    end
    if options.lease_timeout_ms then
        options.lease_timeout_ms = positive_integer('lease-timeout-ms',
            options.lease_timeout_ms)
    end
    if options.lease_check_frames then
        options.lease_check_frames = positive_integer('lease-check-frames',
            options.lease_check_frames)
    end
    if options.run_id then
        assert(options.run_id:match('^[%w_.-]+$'),
            '--run-id contains unsupported characters')
    end
    if options.generation then
        options.generation = positive_integer('generation', options.generation)
    end
    if options.reason then
        assert(#options.reason <= 1024,
            '--reason must not exceed 1024 bytes')
    end
end

---Parses options through argparse and applies DwarfSpec defaults and validation.
---@param argv string[]
---@param start_index integer
---@param package_root string
---@param allowed table
---@return table, string[]
local function parse_options(argv, start_index, package_root, allowed)
    local arguments = {}
    for index = start_index, #argv do table.insert(arguments, argv[index]) end
    reject_empty_inline_assignments(arguments, allowed)
    local parsed_ok, parsed = command_parser(argv[1], allowed):pparse(arguments)
    assert(parsed_ok, 'command syntax: ' .. parser_message(parsed))
    local options = defaults(package_root)
    for name, value in pairs(parsed) do
        if name ~= 'positionals' and value ~= nil then options[name] = value end
    end
    if options.no_results then options.result_path = false end
    options.no_results = nil
    validate_options(options)
    return options, parsed.positionals or {}
end

---Prints command-specific help without performing discovery or connection.
---@param topic string|nil
---@param output any
---@return integer
local function help(topic, output)
    if topic == nil then
        write(output, HELP)
    elseif topic == 'list' then
        write(output, LIST_HELP)
    elseif topic == 'run' then
        write(output, RUN_HELP)
    elseif topic == 'abort' then
        write(output, ABORT_HELP)
    elseif topic == 'status' then
        write(output, STATUS_HELP)
    elseif topic == 'history' then
        write(output, HISTORY_HELP)
    elseif topic == 'show' then
        write(output, SHOW_HELP)
    elseif topic == 'logs' then
        write(output, LOGS_HELP)
    elseif topic == 'recover-executor' then
        write(output, RECOVER_EXECUTOR_HELP)
    else
        error('unknown help topic: ' .. topic, 2)
    end
    return 0
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
    options.test_glob = options.test_glob or
        options.environment.getenv('DWARFSPEC_TEST_GLOB') or
        config.load_test_glob(options.project_root, filesystem,
            context.loadfile)
    local identities = project.discover(options.project_root, filesystem,
        options.test_glob)
    local selected = glob.select(identities, expression)
    assert(#selected > 0, expression and
        ('glob matched no DwarfSpec tests: ' .. expression) or
        'project contains no DwarfSpec tests')
    return selected
end

---Runs the parsed DwarfSpec command and returns its process exit code.
---@param argv string[]
---@param context table|nil
---@return integer
function M.main(argv, context)
    context = context or {}
    local output = context.output or io.stdout
    local errors = context.errors or io.stderr
    local package_root = assert(context.package_root,
        'DwarfSpec package root was not provided')
    local command = argv[1]
    if command == nil then return help(nil, output) end

    local ok, result = xpcall(function()
        if command == 'help' then
            assert(#argv <= 2, 'help accepts at most one command name')
            return help(argv[2], output)
        elseif command == 'version' then
            assert(#argv == 1, 'version does not accept arguments')
            write(output, 'DwarfSpec ' .. M.version)
            return 0
        elseif command == 'list' then
            local options, positionals = parse_options(argv, 2, package_root,
                LIST_OPTIONS)
            assert(#positionals <= 1, 'list accepts at most one glob')
            local selected = select_identities(options, positionals[1],
                context)
            for _, identity in ipairs(selected) do write(output, identity) end
            return 0
        elseif command == 'run' then
            local options, positionals = parse_options(argv, 2, package_root,
                RUN_OPTIONS)
            assert(#positionals <= 1, 'run accepts at most one glob')
            options.identities = select_identities(options, positionals[1],
                context)
            options.emit = function(line) write(output, line) end
            options.host_scripts = context.host_scripts
            options.invoke = context.invoke
            options.system = context.system
            options.now = context.now
            options.sleep = context.sleep
            options.decode_json = context.decode_json
            local outcome = (context.runner or runner).run(options)
            if outcome.error then write(errors, outcome.error.message) end
            return outcome.exit_code
        elseif command == 'status' then
            local options, positionals = parse_options(argv, 2, package_root,
                STATUS_OPTIONS)
            assert(#positionals == 0, 'status does not accept arguments')
            resolve_project_environment(options, context)
            options.host_scripts = context.host_scripts
            options.invoke = context.invoke
            options.decode_json = context.decode_json
            options.emit = function(line) write(output, line) end
            local outcome = (context.runner or runner).status(options)
            if outcome.status then
                for _, line in ipairs(
                        require('dwarfspec.report').format_status(
                            outcome.status)) do
                    write(output, line)
                end
            end
            if outcome.error then write(errors, outcome.error.message) end
            return outcome.exit_code
        elseif command == 'history' then
            local options, positionals = parse_options(argv, 2, package_root,
                READ_OPTIONS)
            assert(#positionals == 0, 'history does not accept arguments')
            resolve_project_environment(options, context)
            options.host_scripts = context.host_scripts
            options.invoke = context.invoke
            options.decode_json = context.decode_json
            options.emit = function(line) write(output, line) end
            local outcome = (context.runner or runner).history(options)
            if outcome.history then
                for _, line in ipairs(
                        require('dwarfspec.report').format_run_history(
                            outcome.history)) do
                    write(output, line)
                end
            end
            if outcome.error then write(errors, outcome.error.message) end
            return outcome.exit_code
        elseif command == 'show' then
            local options, positionals = parse_options(argv, 2, package_root,
                READ_OPTIONS)
            assert(#positionals == 1, 'show requires exactly one run id')
            resolve_project_environment(options, context)
            options.host_scripts = context.host_scripts
            options.invoke = context.invoke
            options.decode_json = context.decode_json
            options.emit = function(line) write(output, line) end
            local outcome = (context.runner or runner).inspect(options,
                positionals[1])
            if outcome.inspection and outcome.inspection.found then
                for _, line in ipairs(
                        require('dwarfspec.report').format_run_inspection(
                            outcome.inspection)) do
                    write(output, line)
                end
            end
            if outcome.error then write(errors, outcome.error.message) end
            return outcome.exit_code
        elseif command == 'logs' then
            local options, positionals = parse_options(argv, 2, package_root,
                READ_OPTIONS)
            assert(#positionals == 1, 'logs requires exactly one run id')
            resolve_project_environment(options, context)
            options.host_scripts = context.host_scripts
            options.invoke = context.invoke
            options.decode_json = context.decode_json
            options.emit = function(line) write(output, line) end
            local outcome = (context.runner or runner).logs(options,
                positionals[1])
            if outcome.logs and outcome.logs.found then
                for _, line in ipairs(outcome.logs.lines) do
                    write(output, line)
                end
            end
            if outcome.error then write(errors, outcome.error.message) end
            return outcome.exit_code
        elseif command == 'abort' then
            local options, positionals = parse_options(argv, 2, package_root,
                ABORT_OPTIONS)
            assert(#positionals == 1, 'abort requires exactly one run id')
            resolve_project_environment(options, context)
            options.host_scripts = context.host_scripts
            options.invoke = context.invoke
            options.decode_json = context.decode_json
            options.emit = function(line) write(output, line) end
            local outcome = (context.runner or runner).abort(options,
                positionals[1])
            if outcome.error then write(errors, outcome.error.message) end
            return outcome.exit_code
        elseif command == 'recover-executor' then
            local options, positionals = parse_options(argv, 2, package_root,
                RECOVER_EXECUTOR_OPTIONS)
            assert(#positionals == 1,
                'recover-executor requires exactly one run id')
            assert(options.generation ~= nil,
                'recover-executor requires --generation')
            resolve_project_environment(options, context)
            options.host_scripts = context.host_scripts
            options.invoke = context.invoke
            options.decode_json = context.decode_json
            options.emit = function(line) write(output, line) end
            local outcome = (context.runner or runner).recover_executor(
                options, positionals[1], options.generation, options.reason)
            if outcome.scheduler then
                for _, line in ipairs(
                        require('dwarfspec.report').format_scheduler(
                            outcome.scheduler)) do
                    write(output, line)
                end
            end
            if outcome.error then write(errors, outcome.error.message) end
            return outcome.exit_code
        else
            error('unknown command: ' .. command, 2)
        end
    end, function(value) return value end)

    if ok then return result end
    local message = clean_message(type(result) == 'table' and
        result.message or result)
    write(errors, message)
    if message:match('command syntax:') or message:match('malformed glob:') or
            message:match('unknown option:') or
            message:match('accepts at most') or message:match('requires') or
            message:match('does not accept') or message:match('must be') or
            message:match('must not') or
            message:match('contains unsupported') or
            message:match('unknown command:') or
            message:match('unknown help topic:') then
        return runner.exit_codes[runner.failure_kinds.USAGE]
    end
    return runner.exit_codes[runner.failure_kinds.DEPENDENCY]
end

return M
