-- Unit contracts for isolated consumer configuration and ds extensions.

local project_module = assert(loadfile(
    'tests/automation/support/project.lua'))()
local extensions = assert(loadfile(
    'tests/automation/support/extensions.lua'))()

describe('DwarfSpec consumer extensions', function()
    local modules
    local descriptor

    before_each(function()
        modules = {}
        descriptor = {
            project_root='consumer',
            package_root='.',
            tests_root='consumer/tests',
            filesystem={
                isfile=function(path)
                    return modules[path:gsub('\\', '/')] ~= nil
                end,
                isdir=function(path)
                    return path:gsub('\\', '/') ==
                        'consumer/tests/dwarfspec'
                end,
                listdir=function()
                    return {'commands.lua', 'config.lua', 'duplicate.lua'}
                end,
            },
        }
    end)

    ---Returns a deterministic in-memory consumer module loader.
    ---@param path string
    ---@return function|nil, string|nil
    local function loader(path)
        local result = modules[path:gsub('\\', '/')]
        if not result then return nil, 'missing test module' end
        return function() return result end
    end

    it('loads config first and registers commands and diagnostics', function()
        modules['consumer/tests/dwarfspec/config.lua'] = {
            settings={wait={frame_budget=42, timeout_ms=900}},
            diagnostics={tooltip=function() return 'tooltip' end},
        }
        modules['consumer/tests/dwarfspec/commands.lua'] = {
            commands={consumer_action=function() return 'action' end},
        }
        modules['consumer/tests/dwarfspec/duplicate.lua'] = {}

        local loaded = extensions.load(descriptor, loader)

        assert.same({'tests/dwarfspec/config.lua',
            'tests/dwarfspec/commands.lua',
            'tests/dwarfspec/duplicate.lua'}, loaded.modules)
        assert.equals(42, loaded.settings.wait.frame_budget)
        assert.equals('action', loaded.commands.consumer_action.callback())
        assert.equals('tooltip', loaded.diagnostics.tooltip.callback())
    end)

    it('rejects duplicate commands with both source modules identified',
            function()
        modules['consumer/tests/dwarfspec/config.lua'] = {
            commands={same=function() end},
        }
        modules['consumer/tests/dwarfspec/commands.lua'] = {
            commands={same=function() end},
        }
        modules['consumer/tests/dwarfspec/duplicate.lua'] = {}

        assert.has_error(function() extensions.load(descriptor, loader) end,
            'tests/dwarfspec/commands.lua: duplicate commands "same"; ' ..
            'first registered by tests/dwarfspec/config.lua')
    end)

    it('rejects invalid schemas and built-in command conflicts', function()
        modules['consumer/tests/dwarfspec/config.lua'] = {
            settings={wait={timeout_ms=0}},
        }
        modules['consumer/tests/dwarfspec/commands.lua'] = {}
        modules['consumer/tests/dwarfspec/duplicate.lua'] = {}
        assert.has_error(function() extensions.load(descriptor, loader) end,
            'tests/dwarfspec/config.lua: settings.wait.timeout_ms must be a ' ..
            'positive integer')

        modules['consumer/tests/dwarfspec/config.lua'] = {
            commands={click=function() end},
        }
        assert.has_error(function() extensions.load(descriptor, loader) end,
            'tests/dwarfspec/config.lua: custom command conflicts with ds.click')
    end)
end)
