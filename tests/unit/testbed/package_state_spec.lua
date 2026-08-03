-- TestBed private package-state and require contracts.

local config = require('dwarfspec.testbed.config')
local Paths = require('dwarfspec.testbed.paths').Paths
local BaseEnvironment = require('dwarfspec.testbed.base_environment').BaseEnvironment
local PackageState = require('dwarfspec.testbed.package_state').PackageState
local ScriptLoader = require('dwarfspec.testbed.script_loader').ScriptLoader
local VirtualFilesystem = dofile('tests/unit/testbed/virtual_filesystem.lua').VirtualFilesystem
local fixtures = dofile('tests/unit/testbed/consumer_fixtures.lua')

---Builds one wired private package state with a private base facade.
---@param filesystem dwarfspec.testbed.spec.VirtualFilesystem
---@param input? table
---@param options? table
---@return dwarfspec.testbed.PackageState
local function new_state(filesystem, input, options)
    options = filesystem:options(options)
    local normalized = config.normalize(input, options)
    local paths = Paths.new(normalized, options)
    local state = PackageState.new(normalized, paths, {closed=false},
        {loadfile=options.loadfile})
    local base = BaseEnvironment.new(normalized, {loaders={package=state.package,
        require=function(name) return state:require(name) end,
        reqscript=function(name) return state:reqscript(name) end,
        mkmodule=function(name) return state:mkmodule(name) end,
    }}).base
    state:set_base(base)
    ScriptLoader.new(state, {read_source=options.read_source,
        load_chunk=options.load_chunk, loadfile=options.loadfile})
    return state
end

describe('TestBed package state', function()
    it('owns mutable package state and preserves the dfhack facade identity', function()
        local filesystem = VirtualFilesystem.new()
        local root = filesystem.root
        local state = new_state(filesystem, {globals={dfhack={mock=true}}})
        local process_path = package.path
        state.package.loaded.dfhack = 'redirected'
        state.package.preload.dfhack = function() return 'redirected' end
        state.package.searchers = {function() return function() return 'redirected' end end}

        assert.is_true(state:require('dfhack').mock)
        assert.equals(process_path, package.path)
        assert.is_nil(package.preload.dfhack)
        state:close()
        assert.is_nil(state.loadfile)
    end)

    it('loads nested source modules into one private graph with deterministic data', function()
        local filesystem = VirtualFilesystem.new()
        local root = filesystem.root
        filesystem:add('source/outer.lua', "local inner = require('inner'); counter = (counter or 0) + 1; return {inner=inner, counter=counter, env=_G}")
        filesystem:add('source/inner.lua', "return {package=package, env=_G}")
        local first = new_state(filesystem, {module_roots={'source'}})
        local second = new_state(filesystem, {module_roots={'source'}})
        local outer, data = first:require('outer')
        local again, cache_data = first:require('outer')
        local other = second:require('outer')

        assert.equals(root .. '/source/outer.lua', data)
        assert.equals('outer', first.record.name)
        assert.equals(data, first.record.loader_data)
        assert.equals('table', first.record.result_type)
        assert.is_nil(cache_data)
        assert.equals(outer, again)
        assert.equals(1, outer.counter)
        assert.equals(first.package, outer.inner.package)
        assert.equals(outer.env, outer.env._G)
        assert.not_equals(outer, other)
        assert.not_equals(outer.inner, other.inner)
    end)

    it('caches true when a conventional source module returns nil without publishing', function()
        local filesystem = VirtualFilesystem.new()
        filesystem:add_all(fixtures.CONVENTIONAL)
        local counter = {nil_calls=0}
        local state = new_state(filesystem, {module_roots={'modules'},
            globals={counter=counter}})
        local first, first_data = state:require('nil_result')
        local second, second_data = state:require('nil_result')

        assert.is_true(first)
        assert.is_true(second)
        assert.is_string(first_data)
        assert.is_nil(second_data)
        assert.equals(1, counter.nil_calls)
    end)

    it('reloads a conventional source module whose returned cache value is false', function()
        local filesystem = VirtualFilesystem.new()
        filesystem:add_all(fixtures.CONVENTIONAL)
        local counter = {calls=0}
        local state = new_state(filesystem, {module_roots={'modules'},
            globals={counter=counter}})
        local first, first_data = state:require('false_result')
        local second, second_data = state:require('false_result')

        assert.is_false(first)
        assert.is_false(second)
        assert.is_string(first_data)
        assert.is_string(second_data)
        assert.equals(2, counter.calls)
    end)

    it('preserves published values for nil returns and prioritizes explicit returns', function()
        local filesystem = VirtualFilesystem.new()
        filesystem:add_all(fixtures.CONVENTIONAL)
        local state = new_state(filesystem, {module_roots={'modules'}})

        assert.equals('published', state:require('published_nil').kind)
        assert.equals('returned', state:require('returned_override').kind)
        assert.equals('published', state.loaded.published_nil.kind)
        assert.equals('returned', state.loaded.returned_override.kind)
    end)

    it('accepts a circular source graph that publishes partial state before re-entry', function()
        local filesystem = VirtualFilesystem.new()
        filesystem:add_all(fixtures.CONVENTIONAL)
        local state = new_state(filesystem, {module_roots={'modules'}})
        local a = state:require('published.a')

        assert.equals(a, a.b.a)
        assert.is_true(a.b.saw_started)
        assert.is_nil(a.b.saw_finished)
        assert.is_true(a.finished)
    end)

    it('retries a conventional source module after an uncommitted failure', function()
        local filesystem = VirtualFilesystem.new()
        filesystem:add_all(fixtures.CONVENTIONAL)
        local state = new_state(filesystem, {module_roots={'modules'}})

        assert.has_error(function() state:require('retry') end)
        assert.is_nil(state.active.retry)
        assert.is_nil(state.loaded.retry)
        filesystem:add('modules/retry.lua', "return {retried=true}")
        assert.is_true(state:require('retry').retried)
    end)

    it('honors authoritative cache, preload, searchers, paths, and provider data', function()
        local filesystem = VirtualFilesystem.new()
        local root = filesystem.root
        filesystem:add('source/shadow.lua', 'return "source"')
        local state = new_state(filesystem, {module_roots={'source'}, imports={
            {provide={kind='module', name='value'}, use_value=false},
            {provide={kind='module', name='alias'}, use_existing={kind='module', name='value'}},
            {provide={kind='module', name='shadow'}, use_value='provider'},
        }})
        state.package.loaded.cached = false
        state.package.preload.cached = function() return 'reloaded' end
        state.package.preload.preloaded = function(_, data) return data end
        local false_value, value_data = state:require('value')
        local alias, alias_data = state:require('alias')
        local preload, preload_data = state:require('preloaded')
        assert.equals('provider', state:require('shadow'))
        state.package.searchers[2] = function(name)
            if name == 'custom' then return function(_, data) return data end, ':custom:' end
            return "\n\tno custom '" .. name .. "'"
        end
        local custom, custom_data = state:require('custom')

        assert.equals('reloaded', state:require('cached'))
        assert.is_false(false_value)
        assert.equals(':testbed:use_value:module:value', value_data)
        assert.is_false(alias)
        assert.equals(':testbed:use_existing:module:alias', alias_data)
        assert.equals(':preload:', preload)
        assert.equals(':preload:', preload_data)
        assert.equals(':custom:', custom)
        assert.equals(':custom:', custom_data)
        assert.equals(root .. '/source/shadow.lua',
            state.package.searchpath('shadow', state.package.path))
        assert.has_error(function() state.package.searchpath('shadow') end)
    end)

    it('resolves each module provider strategy with exact data and identities', function()
        local filesystem = VirtualFilesystem.new()
        local root = filesystem.root
        filesystem:add('shim.lua', 'return {source=true, package=package}')
        local host_calls, host_value = {}, {host=true}
        local state = new_state(filesystem, {imports={
            {provide={kind='module', name='value'}, use_value=false},
            {provide={kind='module', name='source'}, use_source='shim.lua'},
            {provide={kind='module', name='host'}, use_host=true},
            {provide={kind='module', name='alias'}, use_existing={kind='module', name='source'}},
            {provide={kind='script', name='source'}, use_value={script=true}},
        }}, {
            host_importer=function(kind, name)
                table.insert(host_calls, {kind=kind, name=name})
                return host_value
            end,
        })
        local value, value_data = state:require('value')
        local source, source_data = state:require('source')
        local host, host_data = state:require('host')
        local borrowed_host = state.record.borrowed_host
        local alias, alias_data = state:require('alias')
        local cached, cached_data = state:require('host')

        assert.is_false(value)
        assert.equals(':testbed:use_value:module:value', value_data)
        assert.is_true(source.source)
        assert.equals(root .. '/shim.lua', source_data)
        assert.equals(state.package, source.package)
        assert.equals(host_value, host)
        assert.equals(':testbed:use_host:module:host', host_data)
        assert.is_true(borrowed_host)
        assert.equals(source, alias)
        assert.equals(':testbed:use_existing:module:alias', alias_data)
        assert.equals(host, cached)
        assert.is_nil(cached_data)
        assert.same({{kind='module', name='host'}}, host_calls)
        assert.is_nil(state.normalized.provider_registry.module.source.script)
        assert.is_true(state.normalized.provider_registry.script.source.use_value.script)
    end)

    it('reports provider strategy failures and bounds alias-only cycles', function()
        local filesystem = VirtualFilesystem.new()
        local root = filesystem.root
        local host_calls = 0
        local state = new_state(filesystem, {imports={
            {provide={kind='module', name='first'}, use_existing={kind='module', name='second'}},
            {provide={kind='module', name='second'}, use_existing={kind='module', name='first'}},
            {provide={kind='module', name='plugins.native'}, use_host=true},
        }}, {
            host_importer=function(_, name)
                host_calls = host_calls + 1
                error('host unavailable: ' .. name)
            end,
        })
        local cycle_ok, cycle_message = pcall(function() state:require('first') end)
        local host_ok, host_message = pcall(function() state:require('plugins.native') end)

        assert.is_false(cycle_ok)
        assert.is_truthy(cycle_message:find('TestBed circular require: first -> second -> first', 1, true))
        assert.is_truthy(cycle_message:find('module provider "first" (use_existing)', 1, true))
        assert.is_false(host_ok)
        assert.is_truthy(host_message:find('module provider "plugins.native" (use_host, borrowed host value)', 1, true))
        assert.equals(1, host_calls)
        assert.is_nil(state.active.first)
        assert.is_nil(state.active.second)
        assert.is_nil(state.active['plugins.native'])
    end)

    it('keeps plugin fakes and source shims away from the host importer', function()
        local filesystem = VirtualFilesystem.new()
        local root = filesystem.root
        filesystem:add('plugin_shim.lua', 'return {shim=true}')
        local host_calls, fake = 0, {fake=true}
        local state = new_state(filesystem, {imports={
            {provide={kind='module', name='plugins.fake'}, use_value=fake},
            {provide={kind='module', name='plugins.shim'}, use_source='plugin_shim.lua'},
            {provide={kind='module', name='plugins.native'}, use_host=true},
        }}, {
            host_importer=function(_, name)
                host_calls = host_calls + 1
                return {native=name}
            end,
        })

        assert.equals(fake, state:require('plugins.fake'))
        assert.is_true(state:require('plugins.shim').shim)
        assert.equals('plugins.native', state:require('plugins.native').native)
        assert.equals(1, host_calls)
    end)

    it('retains loader cache writes while clearing failures and rejects malformed searchers', function()
        local filesystem = VirtualFilesystem.new()
        local root = filesystem.root
        local state = new_state(filesystem)
        state.package.preload.failure = function()
            state.loaded.failure = 'retained'
            error('expected loader failure')
        end
        local failure_ok = pcall(function() state:require('failure') end)

        assert.is_false(failure_ok)
        assert.is_nil(state.active.failure)
        assert.equals('retained', state:require('failure'))
        state.package.searchers = {false}
        assert.has_error(function() state:require('malformed') end)
        assert.is_nil(state.active.malformed)
    end)

    it('retries a failed loader when no ordinary cache value was published', function()
        local filesystem = VirtualFilesystem.new()
        local root = filesystem.root
        local state = new_state(filesystem)
        local attempts = 0
        state.package.preload.retry = function()
            attempts = attempts + 1
            if attempts == 1 then error('expected first failure') end
            return 'retried'
        end

        assert.has_error(function() state:require('retry') end)
        assert.is_nil(state.active.retry)
        assert.is_nil(state.loaded.retry)
        assert.equals('retried', state:require('retry'))
        assert.equals(2, attempts)
    end)

    it('keeps internal cache tables after exposed references are replaced and bounds failures', function()
        local filesystem = VirtualFilesystem.new()
        local root = filesystem.root
        filesystem:add('source/a.lua', "return require('b')")
        filesystem:add('source/b.lua', "return require('a')")
        local state = new_state(filesystem, {module_roots={'source'}})
        local internal_loaded, internal_preload = state.loaded, state.preload
        state.package.loaded, state.package.preload = {}, {}
        internal_preload.replaced = function() return 'private preload' end

        assert.equals('private preload', state:require('replaced'))
        assert.equals(internal_loaded, state.loaded)
        local cycle_ok, cycle_message = pcall(function() state:require('a') end)
        local missing_ok, missing_message = pcall(function() state:require('missing') end)
        assert.is_false(cycle_ok)
        assert.is_false(missing_ok)
        assert.is_truthy(cycle_message:find('circular require', 1, true))
        assert.is_truthy(missing_message:find('TestBed dependency chain', 1, true))
        assert.is_nil(state.active.a)
        assert.is_nil(state.active.b)
    end)

    it('publishes stable mkmodule environments immediately and isolates them per bed', function()
        local filesystem = VirtualFilesystem.new()
        local root = filesystem.root
        local first, second, empty = new_state(filesystem), new_state(filesystem),
            new_state(filesystem)
        local provider_state = new_state(filesystem, {imports={
            {provide={kind='module', name=''}, use_value='empty provider'},
        }})
        local module = first:mkmodule('')
        module.value = true

        assert.equals(module, first:mkmodule(''))
        assert.equals(module, first.loaded[''])
        assert.is_true(first:require('').value)
        assert.not_equals(module, second:mkmodule(''))
        assert.equals('empty provider', provider_state:require(''))
        local missing_ok = pcall(function() empty:require('') end)
        assert.is_false(missing_ok)
        assert.has_error(function() first:require(1) end)
        assert.has_error(function() first:mkmodule(1) end)
    end)

    it('loads annotated scripts into isolated, self-referential environments', function()
        local filesystem = VirtualFilesystem.new()
        local root = filesystem.root
        filesystem:add('scripts/file.lua', 'return _G')
        filesystem:add('scripts/worker.lua', '--@ module=true\nvalue = (value or 0) + 1; _G.same = value; command_only = not dfhack_flags.module; local dep = require("dep"); local nested = reqscript("nested"); loaded = dep.value + nested.value; dynamic = assert(load("return _G"))(); from_file = assert(loadfile("' .. root .. '/scripts/file.lua"))(); from_dofile = dofile("' .. root .. '/scripts/file.lua")')
        filesystem:add('scripts/nested.lua', '--@ module=true\nvalue = 2')
        filesystem:add('modules/dep.lua', 'return {value=3}')
        local first = new_state(filesystem, {script_roots={'scripts'}, module_roots={'modules'}})
        local second = new_state(filesystem, {script_roots={'scripts'}, module_roots={'modules'}})
        local script = first:reqscript('worker')

        assert.equals(script, first:reqscript('worker'))
        assert.equals(script, first:dfhack().reqscript('worker'))
        assert.equals(script, script._G)
        assert.equals(1, script.value)
        assert.equals(1, script.same)
        assert.is_false(script.command_only)
        assert.equals(5, script.loaded)
        assert.equals(script, script.dynamic)
        assert.equals(script, script.from_file)
        assert.equals(script, script.from_dofile)
        assert.is_true(script.dfhack_flags.module)
        assert.equals(1, second:reqscript('worker').value)
    end)

    it('supports source scripts, script providers, aliases, and circular imports', function()
        local filesystem = VirtualFilesystem.new()
        local root = filesystem.root
        filesystem:add('source.lua', '--@ module=true\nsource = true')
        filesystem:add('scripts/a.lua', '--@ module=true\nb = reqscript("b"); value = b')
        filesystem:add('scripts/b.lua', '--@ module=true\na = reqscript("a"); value = a')
        local host_calls, host_value = 0, {host=true}
        local state = new_state(filesystem, {script_roots={'scripts'}, imports={
            {provide={kind='script', name='source'}, use_source='source.lua'},
            {provide={kind='script', name='value'}, use_value={value=true}},
            {provide={kind='script', name='alias'}, use_existing={kind='script', name='value'}},
            {provide={kind='script', name='host'}, use_host=true},
            {provide={kind='script', name=''}, use_value={empty=true}},
        }}, {host_importer=function(kind, name)
            host_calls = host_calls + 1
            assert.equals('script', kind)
            assert.equals('host', name)
            return host_value
        end})
        local source, a = state:reqscript('source'), state:reqscript('a')

        assert.is_true(source.source)
        assert.is_true(source.dfhack_flags.module)
        assert.equals(a, a.b.value)
        assert.equals(state:reqscript('value'), state:reqscript('alias'))
        assert.is_nil(state:reqscript('value').dfhack_flags)
        assert.is_nil(state:reqscript('alias').dfhack_flags)
        assert.equals(host_value, state:reqscript('host'))
        assert.is_nil(state:reqscript('host').dfhack_flags)
        assert.is_true(state:reqscript('').empty)
        assert.equals(1, host_calls)
    end)

    it('rejects invalid scripts and clears failed state for a retry', function()
        local filesystem = VirtualFilesystem.new()
        local root = filesystem.root
        filesystem:add('scripts/missing.lua', 'executed = true')
        filesystem:add('scripts/legacy.lua', '--@ moduleMode=true')
        filesystem:add('scripts/retry.lua', '--@ module=true\nif not attempted then attempted = true; error("retry") end')
        local state = new_state(filesystem, {script_roots={'scripts'}})

        local missing_ok, missing_message = pcall(function() state:reqscript('missing') end)
        local legacy_ok, legacy_message = pcall(function() state:reqscript('legacy') end)
        assert.is_false(missing_ok)
        assert.is_false(legacy_ok)
        assert.is_truthy(missing_message:find('module=true', 1, true))
        assert.is_truthy(legacy_message:find('module=true', 1, true))
        local retry_ok, retry_message = pcall(function() state:reqscript('retry') end)
        assert.is_false(retry_ok)
        assert.is_truthy(retry_message:find('retry', 1, true))
        assert.is_nil(state.script_loader.active.retry)
        assert.is_nil(state.script_loader.scripts.retry)
        filesystem:add('scripts/retry.lua', '--@ module=true\nretried = true')
        assert.is_true(state:reqscript('retry').retried)
        assert.has_error(function() state:reqscript(1) end)
        local absent_ok, absent_message = pcall(function() state:reqscript('') end)
        assert.is_false(absent_ok)
        assert.is_truthy(absent_message:find('TestBed script dependency chain', 1, true))
    end)
end)
