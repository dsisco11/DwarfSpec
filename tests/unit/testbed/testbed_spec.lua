-- Framework-neutral public TestBed entry-point contracts.

local lfs = require('lfs')

---Creates an empty temporary consumer root.
---@return string
local function temporary_directory()
    local directory = os.tmpname()
    os.remove(directory)
    assert(lfs.mkdir(directory))
    return directory:gsub('\\', '/')
end

---Writes one fixture file, creating its parent directories.
---@param root string
---@param relative string
---@param content string
local function write_file(root, relative, content)
    local directory = root
    local parent = relative:match('^(.*)/[^/]+$')
    if parent then
        for part in parent:gmatch('[^/]+') do
            directory = directory .. '/' .. part
            if not lfs.attributes(directory) then assert(lfs.mkdir(directory)) end
        end
    end
    local file = assert(io.open(root .. '/' .. relative, 'wb'))
    file:write(content)
    file:close()
end

---Removes one temporary fixture hierarchy.
---@param root string
local function remove_tree(root)
    for entry in lfs.dir(root) do
        if entry ~= '.' and entry ~= '..' then
            local path = root .. '/' .. entry
            if lfs.attributes(path, 'mode') == 'directory' then remove_tree(path)
            else assert(os.remove(path)) end
        end
    end
    assert(lfs.rmdir(root))
end

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

    it('owns standalone conventional module and script graphs through close', function()
        local root = temporary_directory()
        write_file(root, 'modules/value.lua', 'local script = reqscript("worker"); return {value=script.value, keep=function() return "kept" end, deferred=function() return require("other") end}')
        write_file(root, 'modules/other.lua', 'return "later"')
        write_file(root, 'scripts/worker.lua', '--@ module=true\nvalue = (value or 0) + 1')
        local config = {module_roots={root .. '/modules'}, script_roots={root .. '/scripts'}}
        local first, second = require('dwarfspec.testbed').new(config), require('dwarfspec.testbed').new(config)
        local value = first:require('value')
        local script = first:reqscript('worker')

        assert.equals(1, value.value)
        assert.equals(script, first:reqscript('worker'))
        assert.equals(1, second:reqscript('worker').value)
        first:close()
        first:close()
        assert.equals('kept', value.keep())
        assert.has_error(function() first:require('value') end)
        assert.has_error(function() first:reqscript('worker') end)
        assert.has_error(function() value.deferred() end)
        second:close()
        remove_tree(root)
    end)

    it('loads conventional modules and scripts with zero configuration', function()
        local root, previous = temporary_directory(), lfs.currentdir()
        write_file(root, 'src/value.lua', 'return reqscript("worker").value')
        write_file(root, 'src/scripts_modinstalled/worker.lua', '--@ module=true\nvalue = 7')
        assert(lfs.chdir(root))
        local bed = require('dwarfspec.testbed').new()
        local value, script = bed:require('value'), bed:reqscript('worker')
        bed:close()
        assert(lfs.chdir(previous))

        assert.equals(7, value)
        assert.equals(7, script.value)
        remove_tree(root)
    end)

    it('applies configured non-host providers before source loading', function()
        local root = temporary_directory()
        write_file(root, 'modules/consumer.lua', 'local value = require("value"); local script = reqscript("script"); return {value=value, script=script}')
        local value, script = {identity=true}, {script=true}
        local bed = require('dwarfspec.testbed').new({module_roots={root .. '/modules'}, imports={
            {provide={kind='module', name='value'}, use_value=value},
            {provide={kind='module', name='alias'}, use_existing={kind='module', name='value'}},
            {provide={kind='script', name='script'}, use_value=script},
        }})
        local consumer = bed:require('consumer')

        assert.equals(value, consumer.value)
        assert.equals(script, consumer.script)
        assert.equals(value, bed:require('alias'))
        bed:close()
        remove_tree(root)
    end)
end)
