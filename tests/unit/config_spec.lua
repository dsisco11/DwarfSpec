-- Unit contracts for external discovery configuration.

local config = require('dwarfspec.config')

describe('DwarfSpec discovery configuration', function()
    local files
    local modules
    local filesystem

    before_each(function()
        files = {}
        modules = {}
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
        local result = modules[path:gsub('\\', '/')]
        if result == nil then return nil, 'missing synthetic module' end
        return function() return result end
    end

    it('defaults to every recursively visited .ds.lua basename', function()
        assert.equals('*.ds.lua',
            config.load_test_glob('project', filesystem, loader))
    end)

    it('loads a project glob from tests/dwarfspec/config.lua', function()
        local path = 'project/tests/dwarfspec/config.lua'
        files[path] = true
        modules[path] = {
            settings={discovery={test_glob='tests/live/**/*_spec.lua'}},
        }
        assert.equals('tests/live/**/*_spec.lua',
            config.load_test_glob('project', filesystem, loader))
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
end)
