-- Framework-neutral public TestBed entry-point contracts.

---Restores one package-loaded entry after an isolated require attempt.
---@param name string
---@param previous any
local function restore_loaded(name, previous)
    package.loaded[name] = previous
end

describe('dwarfspec.testbed entry point', function()
    it('loads when DFHack globals are unavailable', function()
        local previous_module = package.loaded['dwarfspec.testbed']
        local previous_df = rawget(_G, 'df')
        local previous_dfhack = rawget(_G, 'dfhack')
        package.loaded['dwarfspec.testbed'] = nil
        rawset(_G, 'df', nil)
        rawset(_G, 'dfhack', nil)

        local ok, testbed = pcall(require, 'dwarfspec.testbed')

        rawset(_G, 'df', previous_df)
        rawset(_G, 'dfhack', previous_dfhack)
        restore_loaded('dwarfspec.testbed', previous_module)
        assert.is_true(ok)
        assert.is_table(testbed)
        assert.is_function(testbed.new)
        assert.is_function(testbed.require)
        assert.is_function(testbed.reqscript)
        assert.is_function(testbed.close)
    end)

    it('loads no live-only or test-framework dependencies', function()
        local previous_module = package.loaded['dwarfspec.testbed']
        local previous_require = require
        local loaded_before = {}
        local requested = {}
        local original_path = package.path
        local original_preload = package.preload
        for name in pairs(package.loaded) do loaded_before[name] = true end
        package.loaded['dwarfspec.testbed'] = nil
        _G.require = function(name)
            table.insert(requested, name)
            return previous_require(name)
        end

        local ok, testbed = pcall(require, 'dwarfspec.testbed')

        _G.require = previous_require
        restore_loaded('dwarfspec.testbed', previous_module)
        assert.is_true(ok)
        assert.is_table(testbed)
        assert.equals(original_path, package.path)
        assert.equals(original_preload, package.preload)
        assert.same({'dwarfspec.testbed'}, requested)
        for name in pairs(package.loaded) do
            assert.is_true(loaded_before[name] or name == 'dwarfspec.testbed')
        end
    end)
end)
