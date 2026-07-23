-- Unit contracts for the published DwarfSpec package metadata.

local separator = package.config:sub(1, 1)
local source = debug.getinfo(1, 'S').source:gsub('^@', '')
local tests_root = assert(source:match('^(.*)[/\\][^/\\]+$'))
local repository_root = tests_root .. separator .. '..' .. separator .. '..'

---Finds the repository's single root rockspec.
---@return string
local function find_rockspec()
    local lfs = require('lfs')
    local rockspec
    for name in lfs.dir(repository_root) do
        if name:match('%.rockspec$') then
            assert.is_nil(rockspec,
                'the repository must contain exactly one root rockspec')
            rockspec = name
        end
    end
    return assert(rockspec,
        'the repository must contain exactly one root rockspec')
end

local ROCKSPEC_PATH = find_rockspec()

---Reads one repository file as binary text.
---@param relative_path string
---@return string
local function read_repository_file(relative_path)
    local path = repository_root .. separator ..
        relative_path:gsub('[/\\]', separator)
    local file = assert(io.open(path, 'rb'))
    local contents = assert(file:read('*a'))
    file:close()
    return contents
end

describe('DwarfSpec package contract', function()
    it('supports Lua 5.3 and newer without an artificial upper bound',
            function()
        local rockspec = read_repository_file(ROCKSPEC_PATH)
        assert.matches('"lua >= 5.3"', rockspec, 1, true)
        assert.is_nil(rockspec:find('< 5.4', 1, true))
    end)

    it('publishes the component boundary module', function()
        local rockspec = read_repository_file(ROCKSPEC_PATH)
        assert.matches('["dwarfspec.component"] = ' ..
            '"src/dwarfspec/component.lua"', rockspec, 1, true)
        assert.is_truthy(read_repository_file('src/dwarfspec/component.lua'))
    end)

    it('publishes project dotenv support for the installed command', function()
        local rockspec = read_repository_file(ROCKSPEC_PATH)
        assert.matches('["dwarfspec.dotenv"] = ' ..
            '"src/dwarfspec/dotenv.lua"', rockspec, 1, true)
        assert.is_truthy(read_repository_file('src/dwarfspec/dotenv.lua'))
    end)

    it('publishes mount-context and subject modules', function()
        local rockspec = read_repository_file(ROCKSPEC_PATH)
        assert.matches('["dwarfspec.mount_context"] = ' ..
            '"src/dwarfspec/mount_context.lua"', rockspec, 1, true)
        assert.matches('["dwarfspec.subject"] = ' ..
            '"src/dwarfspec/subject.lua"', rockspec, 1, true)
        assert.is_truthy(read_repository_file(
            'src/dwarfspec/mount_context.lua'))
        assert.is_truthy(read_repository_file('src/dwarfspec/subject.lua'))
    end)

    it('publishes render tracking and live mount adapter modules', function()
        local rockspec = read_repository_file(ROCKSPEC_PATH)
        for name, path in pairs({
                mount_adapters='src/dwarfspec/mount_adapters.lua',
                render_instrumentation=
                    'src/dwarfspec/render_instrumentation.lua',
                render_tracker='src/dwarfspec/render_tracker.lua'}) do
            assert.matches(('["dwarfspec.%s"]'):format(name), rockspec,
                1, true)
            assert.is_truthy(read_repository_file(path))
        end
    end)

    it('publishes registration integration without fixture loaders', function()
        local rockspec = read_repository_file(ROCKSPEC_PATH)
        assert.matches('dwarfspec.automation.overlay_registration',
            rockspec, 1, true)
        assert.is_nil(rockspec:find('fixture_loader', 1, true))
        assert.is_nil(rockspec:find('overlay_fixture', 1, true))
        assert.is_truthy(read_repository_file(
            'tests/automation/support/overlay_registration.lua'))
    end)

    it('publishes automation runtime from authoritative source modules',
            function()
        local rockspec = read_repository_file(ROCKSPEC_PATH)
        for name, path in pairs({
                events='src/dwarfspec/automation/events.lua',
                event_types=
                    'src/dwarfspec/automation/event_types.lua',
                output_handler=
                    'src/dwarfspec/automation/output_handler.lua',
                cleanup='src/dwarfspec/automation/cleanup.lua',
                coroutine_scheduler=
                    'src/dwarfspec/automation/coroutine_scheduler.lua',
                host='src/dwarfspec/automation/host.lua',
                projects='src/dwarfspec/automation/projects.lua',
                result_policies=
                    'src/dwarfspec/automation/result_policies.lua',
                result_states=
                    'src/dwarfspec/automation/result_states.lua',
                run_states='src/dwarfspec/automation/run_states.lua',
                scheduler='src/dwarfspec/automation/scheduler.lua',
                scheduler_failure_kinds=
                    'src/dwarfspec/automation/scheduler_failure_kinds.lua',
                schemas='src/dwarfspec/automation/schemas.lua',
                service='src/dwarfspec/automation/service.lua',
                snapshots='src/dwarfspec/automation/snapshots.lua',
                test_statuses=
                    'src/dwarfspec/automation/test_statuses.lua'}) do
            assert.matches(('["dwarfspec.automation.%s"]'):format(name),
                rockspec, 1, true)
            assert.matches(('"%s"'):format(path), rockspec, 1, true)
            assert.is_truthy(read_repository_file(path))
            assert.is_nil(rockspec:find(
                ('["dwarfspec.automation.%s"] = "tests/'):format(name),
                1, true))
        end
    end)

    it('resolves automation modules from the authoritative source namespace',
            function()
        for _, name in ipairs({
                'dwarfspec.automation.events',
                'dwarfspec.automation.event_types',
                'dwarfspec.automation.output_handler',
                'dwarfspec.automation.cleanup',
                'dwarfspec.automation.coroutine_scheduler',
                'dwarfspec.automation.host',
                'dwarfspec.automation.projects',
                'dwarfspec.automation.result_policies',
                'dwarfspec.automation.result_states',
                'dwarfspec.automation.run_states',
                'dwarfspec.automation.scheduler',
                'dwarfspec.automation.scheduler_failure_kinds',
                'dwarfspec.automation.schemas',
                'dwarfspec.automation.service',
                'dwarfspec.automation.snapshots',
                'dwarfspec.automation.test_statuses'}) do
            local path = assert(package.searchpath(name, package.path))
                :gsub('\\', '/')
            assert.matches('/src/dwarfspec/automation/', path, 1, true)
            assert.is_table(require(name))
        end
    end)

    it('publishes shared enum and runner failure-kind modules', function()
        local rockspec = read_repository_file(ROCKSPEC_PATH)
        for name, path in pairs({
                immutable_enum='src/dwarfspec/immutable_enum.lua',
                runner_failure_kinds=
                    'src/dwarfspec/runner_failure_kinds.lua'}) do
            assert.matches(('["dwarfspec.%s"]'):format(name),
                rockspec, 1, true)
            assert.matches(('"%s"'):format(path), rockspec, 1, true)
            assert.is_truthy(read_repository_file(path))
            assert.is_table(require('dwarfspec.' .. name))
        end
    end)

    it('publishes every version 2 transport adapter', function()
        local rockspec = read_repository_file(ROCKSPEC_PATH)
        for name, path in pairs({
                acknowledge='tests/automation/support/acknowledge.lua',
                abort='tests/automation/support/abort.lua',
                bootstrap='tests/automation/support/bootstrap.lua',
                cancel='tests/automation/support/cancel.lua',
                discard='tests/automation/support/discard.lua',
                event_read='tests/automation/support/events.lua',
                recover='tests/automation/support/recover.lua',
                recover_executor=
                    'tests/automation/support/recover_executor.lua',
                scheduler_status=
                    'tests/automation/support/scheduler_status.lua',
                status='tests/automation/support/status.lua'}) do
            assert.matches(('["dwarfspec.automation.%s"]'):format(name),
                rockspec, 1, true)
            assert.matches(('"%s"'):format(path), rockspec, 1, true)
            assert.is_truthy(read_repository_file(path))
        end
    end)

    it('lets LuaRocks generate the platform command launcher', function()
        local rockspec = read_repository_file(ROCKSPEC_PATH)
        assert.matches('dwarfspec = "bin/dwarfspec"', rockspec, 1, true)
        assert.is_nil(rockspec:find('["dwarfspec.bat"]', 1, true))
    end)

    it('provides a VS Code task for building the portable release rock',
            function()
        local tasks = read_repository_file('.vscode/tasks.json')
        local publish = read_repository_file('tools/Publish.ps1')
        assert.matches('"label": "Publish"', tasks, 1, true)
        assert.matches('${workspaceFolder}\\\\tools\\\\Publish.ps1',
            tasks, 1, true)
        assert.matches("arch = 'all'", publish, 1, true)
        assert.matches('--pack-binary-rock', publish, 1, true)
        assert.matches("$OutputDir = 'dist'", publish, 1, true)
    end)
end)
