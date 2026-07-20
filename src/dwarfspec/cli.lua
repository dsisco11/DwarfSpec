-- Command-line parsing and dispatch for the DwarfSpec executable.

local glob = require('dwarfspec.glob')
local config = require('dwarfspec.config')
local project = require('dwarfspec.project')
local runner = require('dwarfspec.runner')

local M = {
    version='0.1.0',
}

local HELP = [[
DwarfSpec 0.1.0 - live DFHack automation with in-process Busted

Usage:
  dwarfspec
  dwarfspec list [glob] [--project-root PATH] [--test-glob GLOB]
  dwarfspec run [glob] [options]
  dwarfspec abort RUN_ID [--runner PATH]
  dwarfspec help [command]
  dwarfspec version

Commands:
  list     List canonical live-spec identities without executing Lua files.
  run      Run all live specs or the identities selected by one glob.
  abort    Abort one active run and require confirmed cleanup.
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
  --timeout SECONDS            External wall-clock timeout (default: 30)
  --poll-interval-ms MS        Status polling interval (default: 100)
  --startup-delay-frames N     Frames before starting Busted (default: 1)
  --lease-timeout-ms MS        Lost-runner lease timeout (default: 5000)
  --lease-check-frames N       Lease check interval (default: 30)
  --overlay-fixture PATH       Explicit overlay definition (repeatable)
  --results PATH               JSON result directory relative to project root
                               (default: .test-results/dwarfspec)
  --no-results                 Do not persist a JSON run report
  --run-id ID                  Safe explicit run identifier
  --verbose                    Print resolved runner diagnostics

Runner lookup order is --runner, DFHACK_RUNNER, DFHACK_ROOT/hack/dfhack-run,
then PATH. A run returns zero only when Busted passes and cleanup is confirmed.
]]

local ABORT_HELP = [[
Usage: dwarfspec abort RUN_ID [--runner PATH] [--verbose]

Aborts an active DwarfSpec run through dfhack-run. Success requires an aborted
native report with cleanup_confirmed=true.
]]

local LIST_OPTIONS = {['project-root']=true, ['test-glob']=true}
local ABORT_OPTIONS = {runner=true, verbose=true}
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
    ['poll-interval-ms']=true,
    ['startup-delay-frames']=true,
    ['lease-timeout-ms']=true,
    ['lease-check-frames']=true,
    ['overlay-fixture']=true,
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
        dependency_lua_root=nil,
        project_root=nil,
        test_glob=nil,
        runner=nil,
        filters={},
        filter_out={},
        names={},
        tags={},
        exclude_tags={},
        overlay_fixtures={},
        repeat_count=1,
        timeout_seconds=30,
        poll_interval_ms=100,
        startup_delay_frames=1,
        lease_timeout_ms=5000,
        lease_check_frames=30,
        result_directory='.test-results/dwarfspec',
        run_id=nil,
        verbose=false,
    }
end

---Consumes one option value from --name=value or the following argument.
---@param argv string[]
---@param index integer
---@param inline_value string|nil
---@param name string
---@return string, integer
local function option_value(argv, index, inline_value, name)
    if inline_value ~= nil then
        assert(inline_value ~= '', '--' .. name .. ' must not be empty')
        return inline_value, index
    end
    local value = argv[index + 1]
    assert(value and value:sub(1, 2) ~= '--',
        '--' .. name .. ' requires a value')
    return value, index + 1
end

---Parses common list, run, and abort command options.
---@param argv string[]
---@param start_index integer
---@param package_root string
---@param allowed table
---@return table, string[]
local function parse_options(argv, start_index, package_root, allowed)
    local options = defaults(package_root)
    local positionals = {}
    local index = start_index
    while index <= #argv do
        local argument = argv[index]
        local name, inline_value = argument:match('^%-%-([%w-]+)=(.*)$')
        if not name then name = argument:match('^%-%-([%w-]+)$') end
        if not name then
            table.insert(positionals, argument)
        else
            assert(allowed[name], 'unknown option: --' .. name)
        end
        if name then
            if name == 'verbose' then
                assert(inline_value == nil, '--verbose does not take a value')
                options.verbose = true
            elseif name == 'no-results' then
                assert(inline_value == nil,
                    '--no-results does not take a value')
                options.result_directory = false
            else
                local value
                value, index = option_value(argv, index, inline_value, name)
                if name == 'project-root' then
                    options.project_root = value
                elseif name == 'test-glob' then
                    glob.compile(value)
                    options.test_glob = value
                elseif name == 'runner' then
                    options.runner = value
                elseif name == 'filter' then
                    table.insert(options.filters, value)
                elseif name == 'filter-out' then
                    table.insert(options.filter_out, value)
                elseif name == 'name' then
                    table.insert(options.names, value)
                elseif name == 'tag' then
                    table.insert(options.tags, value)
                elseif name == 'exclude-tag' then
                    table.insert(options.exclude_tags, value)
                elseif name == 'overlay-fixture' then
                    table.insert(options.overlay_fixtures, value)
                elseif name == 'repeat' then
                    options.repeat_count = positive_integer(name, value)
                elseif name == 'timeout' then
                    options.timeout_seconds = positive_number(name, value)
                elseif name == 'poll-interval-ms' then
                    options.poll_interval_ms = positive_integer(name, value)
                elseif name == 'startup-delay-frames' then
                    options.startup_delay_frames = positive_integer(name,
                        value)
                elseif name == 'lease-timeout-ms' then
                    options.lease_timeout_ms = positive_integer(name, value)
                elseif name == 'lease-check-frames' then
                    options.lease_check_frames = positive_integer(name, value)
                elseif name == 'results' then
                    options.result_directory = value
                elseif name == 'run-id' then
                    assert(value:match('^[%w_.-]+$'),
                        '--run-id contains unsupported characters')
                    options.run_id = value
                else
                    error('unknown option: --' .. name, 2)
                end
            end
        end
        index = index + 1
    end
    return options, positionals
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
    else
        error('unknown help topic: ' .. topic, 2)
    end
    return 0
end

---Discovers and optionally filters canonical identities for list or run.
---@param options table
---@param expression string|nil
---@param context table
---@return string[]
local function select_identities(options, expression, context)
    local filesystem = context.filesystem or project.filesystem()
    options.filesystem = filesystem
    options.project_root = project.resolve_root(options.project_root,
        context.current_directory or filesystem.currentdir(), filesystem)
    local environment = context.environment or {getenv=os.getenv}
    options.test_glob = options.test_glob or
        environment.getenv('DWARFSPEC_TEST_GLOB') or
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
            options.environment = context.environment
            options.host_scripts = context.host_scripts
            options.dependency_lua_root = context.dependency_lua_root
            options.invoke = context.invoke
            options.system = context.system
            options.now = context.now
            options.sleep = context.sleep
            options.decode_json = context.decode_json
            local outcome = (context.runner or runner).run(options)
            if outcome.error then write(errors, outcome.error.message) end
            return outcome.exit_code
        elseif command == 'abort' then
            local options, positionals = parse_options(argv, 2, package_root,
                ABORT_OPTIONS)
            assert(#positionals == 1, 'abort requires exactly one run id')
            options.environment = context.environment
            options.host_scripts = context.host_scripts
            options.dependency_lua_root = context.dependency_lua_root
            options.invoke = context.invoke
            options.decode_json = context.decode_json
            options.emit = function(line) write(output, line) end
            local outcome = (context.runner or runner).abort(options,
                positionals[1])
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
    if message:match('malformed glob:') or message:match('unknown option:') or
            message:match('accepts at most') or message:match('requires') or
            message:match('must be') or message:match('unknown command:') or
            message:match('unknown help topic:') then
        return runner.exit_codes.usage
    end
    return runner.exit_codes.dependency
end

return M
