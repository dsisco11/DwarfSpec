-- Unit contracts for external project configuration.

local config = require('dwarfspec.config')
local ErrorFormat = require('dwarfspec.error_formats')

describe('DwarfSpec external project configuration', function()
    local files
    local modules
    local filesystem
    local load_counts

    before_each(function()
        files = {}
        modules = {}
        load_counts = {}
        filesystem = {
            isfile=function(path) return files[path:gsub('\\', '/')] == true end,
        }
    end)

    ---Loads one synthetic configuration module in the supplied environment.
    ---@param path string
    ---@param mode string
    ---@param environment table
    ---@return function|nil, string|nil
    local function loader(path, mode, environment)
        assert.equals('t', mode)
        assert.is_table(environment)
        local normalized = path:gsub('\\', '/')
        local result = modules[normalized]
        if result == nil then return nil, 'missing synthetic module' end
        return function()
            load_counts[normalized] = (load_counts[normalized] or 0) + 1
            return result
        end
    end

    it('selects this repository product automation suite by default',
            function()
        local repository_config =
            assert(loadfile('tests/dwarfspec/config.lua'))()

        assert.equals('tests/automation/*.lua',
            repository_config.settings.discovery.test_glob)
    end)

    it('defaults to every recursively visited .ds.lua basename', function()
        assert.equals('*.ds.lua',
            config.load_test_glob('project', filesystem, loader))
        local loaded = config.load('project', filesystem, loader)
        assert.equals('*.ds.lua',
            loaded.settings.discovery.test_glob)
        assert.equals(ErrorFormat.MSBUILD,
            loaded.settings.error_format)
    end)

    it('loads discovery and error format together exactly once', function()
        local path = 'project/tests/dwarfspec/config.lua'
        files[path] = true
        modules[path] = {
            settings={
                discovery={test_glob='tests/live/**/*_spec.lua'},
                error_format=ErrorFormat.GCC,
            },
        }
        local loaded = config.load('project', filesystem, loader)

        assert.equals('tests/live/**/*_spec.lua',
            loaded.settings.discovery.test_glob)
        assert.equals(ErrorFormat.GCC, loaded.settings.error_format)
        assert.equals(1, load_counts[path])
    end)

    it('accepts every immutable error format', function()
        local path = 'project/tests/dwarfspec/config.lua'
        files[path] = true
        for _, error_format in ipairs({
                ErrorFormat.MSBUILD,
                ErrorFormat.GCC,
                ErrorFormat.ESLINT}) do
            modules[path] = {settings={error_format=error_format}}

            local loaded = config.load('project', filesystem, loader)

            assert.equals(error_format, loaded.settings.error_format)
            assert.equals('*.ds.lua',
                loaded.settings.discovery.test_glob)
        end
    end)

    it('keeps error formats independent across project roots', function()
        local alpha_path = 'alpha/tests/dwarfspec/config.lua'
        local beta_path = 'beta/tests/dwarfspec/config.lua'
        files[alpha_path] = true
        files[beta_path] = true
        modules[alpha_path] = {
            settings={error_format=ErrorFormat.GCC},
        }
        modules[beta_path] = {
            settings={error_format=ErrorFormat.ESLINT},
        }

        local alpha = config.load('alpha', filesystem, loader)
        local beta = config.load('beta', filesystem, loader)

        assert.equals(ErrorFormat.GCC, alpha.settings.error_format)
        assert.equals(ErrorFormat.ESLINT, beta.settings.error_format)
        assert.equals(1, load_counts[alpha_path])
        assert.equals(1, load_counts[beta_path])
    end)

    it('rejects empty and malformed configured globs', function()
        local path = 'project/tests/dwarfspec/config.lua'
        files[path] = true
        modules[path] = {settings={discovery={test_glob=''}}}
        assert.has_error(function()
            config.load_test_glob('project', filesystem, loader)
        end, 'tests/dwarfspec/config.lua: ' ..
            'settings.discovery.test_glob must be a nonempty string')

        modules[path].settings.discovery.test_glob = 'tests/***/bad.lua'
        assert.has_error(function()
            config.load_test_glob('project', filesystem, loader)
        end, 'malformed glob: at most two adjacent stars are allowed')
    end)

    it('rejects invalid error formats with the configuration path',
            function()
        local path = 'project/tests/dwarfspec/config.lua'
        files[path] = true
        local cases = {
            {
                value=false,
                expected='tests/dwarfspec/config.lua: ' ..
                    'settings.error_format must be a string',
            },
            {
                value=42,
                expected='tests/dwarfspec/config.lua: ' ..
                    'settings.error_format must be a string',
            },
            {
                value={},
                expected='tests/dwarfspec/config.lua: ' ..
                    'settings.error_format must be a string',
            },
            {
                value='',
                expected='tests/dwarfspec/config.lua: ' ..
                    'settings.error_format must be a nonempty string',
            },
            {
                value='visual-studio',
                expected='tests/dwarfspec/config.lua: ' ..
                    'settings.error_format must be one of: ' ..
                    'msbuild, gcc, eslint',
            },
        }
        for _, case in ipairs(cases) do
            modules[path] = {
                settings={error_format=case.value},
            }

            assert.has_error(function()
                config.load('project', filesystem, loader)
            end, case.expected)
        end
    end)

    it('rejects unknown settings', function()
        local path = 'project/tests/dwarfspec/config.lua'
        files[path] = true
        modules[path] = {
            settings={diagnostic_format='msbuild'},
        }

        assert.has_error(function()
            config.load('project', filesystem, loader)
        end, 'tests/dwarfspec/config.lua: unknown setting: ' ..
            'diagnostic_format')
    end)

    it('matches the in-process configuration module schema', function()
        local path = 'project/tests/dwarfspec/config.lua'
        files[path] = true
        local cases = {
            {
                module={unknown=true},
                expected='tests/dwarfspec/config.lua: ' ..
                    'unknown module field: unknown',
            },
            {
                module={commands='invalid'},
                expected='tests/dwarfspec/config.lua: ' ..
                    'commands must be a table',
            },
            {
                module={commands={redraw=function() end}},
                expected='tests/dwarfspec/config.lua: ' ..
                    'custom command conflicts with ds.redraw',
            },
        }
        for _, case in ipairs(cases) do
            modules[path] = case.module

            assert.has_error(function()
                config.load('project', filesystem, loader)
            end, case.expected)
        end

        modules[path] = {
            settings={error_format=ErrorFormat.GCC},
            commands={consumer_command=function() return true end},
        }
        assert.equals(ErrorFormat.GCC,
            config.load('project', filesystem, loader)
                .settings.error_format)
    end)
end)
