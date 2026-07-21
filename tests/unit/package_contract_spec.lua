-- Unit contracts for the published DwarfSpec package metadata.

local separator = package.config:sub(1, 1)
local source = debug.getinfo(1, 'S').source:gsub('^@', '')
local tests_root = assert(source:match('^(.*)[/\\][^/\\]+$'))
local repository_root = tests_root .. separator .. '..' .. separator .. '..'
local ROCKSPEC_PATH = 'dwarfspec.rockspec'

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
