-- TestBed private package-state and require contracts.

local config = require('dwarfspec.testbed.config')
local Paths = require('dwarfspec.testbed.paths').Paths
local BaseEnvironment = require('dwarfspec.testbed.base_environment').BaseEnvironment
local PackageState = require('dwarfspec.testbed.package_state').PackageState
local ScriptLoader = require('dwarfspec.testbed.script_loader').ScriptLoader
local lfs = require('lfs')

---Creates an empty temporary directory.
---@return string
local function temporary_directory()
    local directory = os.tmpname()
    os.remove(directory)
    assert(lfs.mkdir(directory))
    return directory:gsub('\\', '/')
end

---Creates every parent directory for one relative fixture path.
---@param root string
---@param relative string
local function mkdirs(root, relative)
    local current = root
    for segment in relative:gmatch('[^/]+') do
        current = current .. '/' .. segment
        if not lfs.attributes(current) then assert(lfs.mkdir(current)) end
    end
end

---Writes one Lua fixture below a temporary root.
---@param root string
---@param relative string
---@param content string
local function write_file(root, relative, content)
    local parent = relative:match('^(.*)/[^/]+$')
    if parent then mkdirs(root, parent) end
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

---Builds one wired private package state with a private base facade.
---@param root string
---@param input? table
---@param options? table
---@return dwarfspec.testbed.PackageState
local function new_state(root, input, options)
    options = options or {}
    options.consumer_root = root
    options.directory_exists = function() return true end
    local normalized = config.normalize(input, options)
    local paths = Paths.new(normalized)
    local state = PackageState.new(normalized, paths)
    local base = BaseEnvironment.new(normalized, {loaders={package=state.package,
        require=function(name) return state:require(name) end,
        reqscript=function(name) return state:reqscript(name) end,
        mkmodule=function(name) return state:mkmodule(name) end,
    }}).base
    state:set_base(base)
    ScriptLoader.new(state)
    return state
end

describe('TestBed package state', function()
    it('owns mutable package state and preserves the dfhack facade identity', function()
        local root = temporary_directory()
        local state = new_state(root, {globals={dfhack={mock=true}}})
        local process_path = package.path
        state.package.loaded.dfhack = 'redirected'
        state.package.preload.dfhack = function() return 'redirected' end
        state.package.searchers = {function() return function() return 'redirected' end end}

        assert.is_true(state:require('dfhack').mock)
        assert.equals(process_path, package.path)
        assert.is_nil(package.preload.dfhack)
        remove_tree(root)
    end)

    it('loads nested source modules into one private graph with deterministic data', function()
        local root = temporary_directory()
        write_file(root, 'source/outer.lua', "local inner = require('inner'); counter = (counter or 0) + 1; return {inner=inner, counter=counter, env=_G}")
        write_file(root, 'source/inner.lua', "return {package=package, env=_G}")
        local first = new_state(root, {module_roots={'source'}})
        local second = new_state(root, {module_roots={'source'}})
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
        remove_tree(root)
    end)

    it('honors authoritative cache, preload, searchers, paths, and provider data', function()
        local root = temporary_directory()
        write_file(root, 'source/shadow.lua', 'return "source"')
        local state = new_state(root, {module_roots={'source'}, imports={
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
        remove_tree(root)
    end)

    it('resolves each module provider strategy with exact data and identities', function()
        local root = temporary_directory()
        write_file(root, 'shim.lua', 'return {source=true, package=package}')
        local host_calls, host_value = {}, {host=true}
        local state = new_state(root, {imports={
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
        remove_tree(root)
    end)

    it('reports provider strategy failures and bounds alias-only cycles', function()
        local root = temporary_directory()
        local host_calls = 0
        local state = new_state(root, {imports={
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
        remove_tree(root)
    end)

    it('keeps plugin fakes and source shims away from the host importer', function()
        local root = temporary_directory()
        write_file(root, 'plugin_shim.lua', 'return {shim=true}')
        local host_calls, fake = 0, {fake=true}
        local state = new_state(root, {imports={
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
        remove_tree(root)
    end)

    it('retains loader cache writes while clearing failures and rejects malformed searchers', function()
        local root = temporary_directory()
        local state = new_state(root)
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
        remove_tree(root)
    end)

    it('retries a failed loader when no ordinary cache value was published', function()
        local root = temporary_directory()
        local state = new_state(root)
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
        remove_tree(root)
    end)

    it('keeps internal cache tables after exposed references are replaced and bounds failures', function()
        local root = temporary_directory()
        write_file(root, 'source/a.lua', "return require('b')")
        write_file(root, 'source/b.lua', "return require('a')")
        local state = new_state(root, {module_roots={'source'}})
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
        remove_tree(root)
    end)

    it('publishes stable mkmodule environments immediately and isolates them per bed', function()
        local root = temporary_directory()
        local first, second, empty = new_state(root), new_state(root), new_state(root)
        local provider_state = new_state(root, {imports={
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
        remove_tree(root)
    end)

    it('loads annotated scripts into isolated, self-referential environments', function()
        local root = temporary_directory()
        write_file(root, 'scripts/file.lua', 'return _G')
        write_file(root, 'scripts/worker.lua', '--@ module=true\nvalue = (value or 0) + 1; _G.same = value; command_only = not dfhack_flags.module; local dep = require("dep"); local nested = reqscript("nested"); loaded = dep.value + nested.value; dynamic = assert(load("return _G"))(); from_file = assert(loadfile("' .. root .. '/scripts/file.lua"))(); from_dofile = dofile("' .. root .. '/scripts/file.lua")')
        write_file(root, 'scripts/nested.lua', '--@ module=true\nvalue = 2')
        write_file(root, 'modules/dep.lua', 'return {value=3}')
        local first = new_state(root, {script_roots={'scripts'}, module_roots={'modules'}})
        local second = new_state(root, {script_roots={'scripts'}, module_roots={'modules'}})
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
        remove_tree(root)
    end)

    it('supports source scripts, script providers, aliases, and circular imports', function()
        local root = temporary_directory()
        write_file(root, 'source.lua', '--@ module=true\nsource = true')
        write_file(root, 'scripts/a.lua', '--@ module=true\nb = reqscript("b"); value = b')
        write_file(root, 'scripts/b.lua', '--@ module=true\na = reqscript("a"); value = a')
        local host_calls, host_value = 0, {host=true}
        local state = new_state(root, {script_roots={'scripts'}, imports={
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
        remove_tree(root)
    end)

    it('rejects invalid scripts and clears failed state for a retry', function()
        local root = temporary_directory()
        write_file(root, 'scripts/missing.lua', 'executed = true')
        write_file(root, 'scripts/legacy.lua', '--@ moduleMode=true')
        write_file(root, 'scripts/retry.lua', '--@ module=true\nif not attempted then attempted = true; error("retry") end')
        local state = new_state(root, {script_roots={'scripts'}})

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
        write_file(root, 'scripts/retry.lua', '--@ module=true\nretried = true')
        assert.is_true(state:reqscript('retry').retried)
        assert.has_error(function() state:reqscript(1) end)
        local absent_ok, absent_message = pcall(function() state:reqscript('') end)
        assert.is_false(absent_ok)
        assert.is_truthy(absent_message:find('TestBed script dependency chain', 1, true))
        remove_tree(root)
    end)
end)
