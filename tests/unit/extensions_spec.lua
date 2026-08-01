-- Unit contracts for isolated consumer configuration and ds extensions.

local project_module = assert(loadfile(
    'src/dwarfspec/automation/project.lua'))()
local extensions = assert(loadfile(
    'src/dwarfspec/automation/extensions.lua'))()
local ErrorFormat = require('dwarfspec.error_formats')

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

    it('loads config first and registers commands', function()
        modules['consumer/tests/dwarfspec/config.lua'] = {
            settings={
                wait={frame_budget=42, timeout_ms=900},
                discovery={test_glob='tests/live/*.lua'},
                error_format=ErrorFormat.ESLINT,
            },
            commands={tooltip_state=function() return 'tooltip' end},
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
        assert.equals('tests/live/*.lua',
            loaded.settings.discovery.test_glob)
        assert.equals(ErrorFormat.ESLINT,
            loaded.settings.error_format)
        assert.equals('action', loaded.commands.consumer_action.callback())
        assert.equals('tooltip', loaded.commands.tooltip_state.callback())
    end)

    it('uses the shared default when no config module exists', function()
        modules['consumer/tests/dwarfspec/commands.lua'] = {}
        modules['consumer/tests/dwarfspec/duplicate.lua'] = {}

        local loaded = extensions.load(descriptor, loader)

        assert.equals(ErrorFormat.MSBUILD,
            loaded.settings.error_format)
    end)

    it('accepts every immutable error format in process', function()
        modules['consumer/tests/dwarfspec/commands.lua'] = {}
        modules['consumer/tests/dwarfspec/duplicate.lua'] = {}
        for _, error_format in ipairs({
                ErrorFormat.MSBUILD,
                ErrorFormat.GCC,
                ErrorFormat.ESLINT}) do
            modules['consumer/tests/dwarfspec/config.lua'] = {
                settings={error_format=error_format},
            }

            local loaded = extensions.load(descriptor, loader)

            assert.equals(error_format, loaded.settings.error_format)
        end
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
            settings={discovery={test_glob=''}},
        }
        assert.has_error(function() extensions.load(descriptor, loader) end,
            'tests/dwarfspec/config.lua: ' ..
            'settings.discovery.test_glob must be a nonempty string')

        modules['consumer/tests/dwarfspec/config.lua'] = {
            commands={input=function() end},
        }
        assert.has_error(function() extensions.load(descriptor, loader) end,
            'tests/dwarfspec/config.lua: custom command conflicts with ds.input')

        modules['consumer/tests/dwarfspec/config.lua'] = {
            commands={mount=function() end},
        }
        assert.has_error(function() extensions.load(descriptor, loader) end,
            'tests/dwarfspec/config.lua: custom command conflicts with ds.mount')

        modules['consumer/tests/dwarfspec/config.lua'] = {
            commands={mouseInput=function() end},
        }
        assert.has_error(function() extensions.load(descriptor, loader) end,
            'tests/dwarfspec/config.lua: custom command conflicts with ' ..
            'ds.mouseInput')

        modules['consumer/tests/dwarfspec/config.lua'] = {
            commands={mouseWheel=function() end},
        }
        assert.has_error(function() extensions.load(descriptor, loader) end,
            'tests/dwarfspec/config.lua: custom command conflicts with ' ..
            'ds.mouseWheel')

        modules['consumer/tests/dwarfspec/config.lua'] = {
            commands={EMouseButton=function() end},
        }
        assert.has_error(function() extensions.load(descriptor, loader) end,
            'tests/dwarfspec/config.lua: custom command conflicts with ' ..
            'ds.EMouseButton')

        modules['consumer/tests/dwarfspec/config.lua'] = {
            commands={EInputState=function() end},
        }
        assert.has_error(function() extensions.load(descriptor, loader) end,
            'tests/dwarfspec/config.lua: custom command conflicts with ' ..
            'ds.EInputState')

        modules['consumer/tests/dwarfspec/config.lua'] = {
            commands={EPointerSpace=function() end},
        }
        assert.has_error(function() extensions.load(descriptor, loader) end,
            'tests/dwarfspec/config.lua: custom command conflicts with ' ..
            'ds.EPointerSpace')

        modules['consumer/tests/dwarfspec/config.lua'] = {
            commands={EScreenOrigin=function() end},
        }
        assert.has_error(function() extensions.load(descriptor, loader) end,
            'tests/dwarfspec/config.lua: custom command conflicts with ' ..
            'ds.EScreenOrigin')

        modules['consumer/tests/dwarfspec/config.lua'] = {
            commands={redraw=function() end},
        }
        assert.has_error(function() extensions.load(descriptor, loader) end,
            'tests/dwarfspec/config.lua: custom command conflicts with ' ..
            'ds.redraw')

        modules['consumer/tests/dwarfspec/config.lua'] = {
            commands={wait_ticks=function() end},
        }
        assert.has_error(function() extensions.load(descriptor, loader) end,
            'tests/dwarfspec/config.lua: custom command conflicts with ' ..
            'ds.wait_ticks')

        modules['consumer/tests/dwarfspec/config.lua'] = {
            commands={isGamePaused=function() end},
        }
        assert.has_error(function() extensions.load(descriptor, loader) end,
            'tests/dwarfspec/config.lua: custom command conflicts with ' ..
            'ds.isGamePaused')

        modules['consumer/tests/dwarfspec/config.lua'] = {
            commands={setGamePaused=function() end},
        }
        assert.has_error(function() extensions.load(descriptor, loader) end,
            'tests/dwarfspec/config.lua: custom command conflicts with ' ..
            'ds.setGamePaused')

        modules['consumer/tests/dwarfspec/config.lua'] = {
            commands={getGameSpeed=function() end},
        }
        assert.has_error(function() extensions.load(descriptor, loader) end,
            'tests/dwarfspec/config.lua: custom command conflicts with ' ..
            'ds.getGameSpeed')

        modules['consumer/tests/dwarfspec/config.lua'] = {
            commands={setGameSpeed=function() end},
        }
        assert.has_error(function() extensions.load(descriptor, loader) end,
            'tests/dwarfspec/config.lua: custom command conflicts with ' ..
            'ds.setGameSpeed')

        modules['consumer/tests/dwarfspec/config.lua'] = {
            commands={mountSaveGame=function() end},
        }
        assert.has_error(function() extensions.load(descriptor, loader) end,
            'tests/dwarfspec/config.lua: custom command conflicts with ' ..
            'ds.mountSaveGame')
    end)

    it('matches external error-format and unknown-setting validation',
            function()
        modules['consumer/tests/dwarfspec/commands.lua'] = {}
        modules['consumer/tests/dwarfspec/duplicate.lua'] = {}
        local cases = {
            {
                settings={error_format={}},
                expected='tests/dwarfspec/config.lua: ' ..
                    'settings.error_format must be a string',
            },
            {
                settings={error_format=''},
                expected='tests/dwarfspec/config.lua: ' ..
                    'settings.error_format must be a nonempty string',
            },
            {
                settings={error_format='unknown'},
                expected='tests/dwarfspec/config.lua: ' ..
                    'settings.error_format must be one of: ' ..
                    'msbuild, gcc, eslint',
            },
            {
                settings={unknown=true},
                expected='tests/dwarfspec/config.lua: ' ..
                    'unknown setting: unknown',
            },
        }
        for _, case in ipairs(cases) do
            modules['consumer/tests/dwarfspec/config.lua'] = {
                settings=case.settings,
            }

            assert.has_error(function()
                extensions.load(descriptor, loader)
            end, case.expected)
        end
    end)
end)
