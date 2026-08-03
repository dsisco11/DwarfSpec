-- Framework-neutral public TestBed entry-point contracts.

local TestBed = require('dwarfspec.testbed')
local fixtures = dofile('tests/unit/testbed/fixture_integrity.lua')

local FIXTURE_ROOT = fixtures.FIXTURE_ROOT
local FixtureIntegrityGuard = fixtures.FixtureIntegrityGuard

---Quotes one trusted repository path for the current platform shell.
---@param value string
---@return string
local function shell_quote(value)
    if package.config:sub(1, 1) == '\\' then return '"' .. value .. '"' end
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

---Runs the zero-configuration consumer in a child process rooted at its fixture.
---@return string output
local function run_zero_config_child()
    local lua = assert(arg and arg[-1],
        'Run-UnitTests.ps1 must invoke Busted through the Lua executable')
    local change_directory
    if package.config:sub(1, 1) == '\\' then
        change_directory = 'cd /d ' .. shell_quote(FIXTURE_ROOT)
    else
        change_directory = 'cd ' .. shell_quote(FIXTURE_ROOT)
    end
    local command = change_directory .. ' && ' .. shell_quote(lua) ..
        ' zero_config.lua 2>&1'
    local process = assert(io.popen(command, 'r'))
    local output = process:read('*a')
    local ok, reason, code = process:close()
    assert(ok, ('zero-config child failed (%s %s): %s'):format(
        tostring(reason), tostring(code), output))
    return output
end

---Restores one package-loaded entry after an isolated require attempt.
---@param name string
---@param previous any
local function restore_loaded(name, previous)
    package.loaded[name] = previous
end

describe('dwarfspec.testbed entry point', function()
    local fixture_guard

    before_each(function()
        fixture_guard = FixtureIntegrityGuard.new(assert)
    end)

    after_each(function()
        fixture_guard:assert_unchanged()
    end)

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

    it('constructs a provider-only bed through the public constructor', function()
        local identity = {}
        local bed = TestBed.new({module_roots={}, script_roots={}, imports={
            {provide={kind='module', name='identity'}, use_value=identity},
        }})

        assert.equals(identity, bed:require('identity'))
        bed:close()
        assert.has_error(function() bed:require('identity') end)
    end)

    it('owns standalone conventional module and script graphs through close', function()
        local config = {module_roots={FIXTURE_ROOT .. '/modules'},
            script_roots={FIXTURE_ROOT .. '/scripts'}}
        local first, second = TestBed.new(config), TestBed.new(config)
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
    end)

    it('loads conventional modules and scripts with zero configuration in a child', function()
        assert.is_truthy(run_zero_config_child():find('ZERO_CONFIG_OK', 1, true))
    end)

    it('applies configured non-host providers before source loading', function()
        local value, script = {identity=true}, {script=true}
        local bed = TestBed.new({module_roots={FIXTURE_ROOT .. '/modules'}, imports={
            {provide={kind='module', name='value'}, use_value=value},
            {provide={kind='module', name='alias'},
                use_existing={kind='module', name='value'}},
            {provide={kind='script', name='script'}, use_value=script},
        }})
        local consumer = bed:require('consumer')

        assert.equals(value, consumer.value)
        assert.equals(script, consumer.script)
        assert.equals(value, bed:require('alias'))
        bed:close()
    end)
end)
