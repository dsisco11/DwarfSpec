-- TestBed private package-state and require contracts.

local config = require('dwarfspec.testbed.config')
local Paths = require('dwarfspec.testbed.paths').Paths
local BaseEnvironment = require('dwarfspec.testbed.base_environment').BaseEnvironment
local PackageState = require('dwarfspec.testbed.package_state').PackageState
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
---@return dwarfspec.testbed.PackageState
local function new_state(root, input)
    local normalized = config.normalize(input, {consumer_root=root,
        directory_exists=function() return true end})
    local paths = Paths.new(normalized)
    local state = PackageState.new(normalized, paths)
    local base = BaseEnvironment.new(normalized, {loaders={package=state.package,
        require=function(name) return state:require(name) end,
        reqscript=function() error('unexpected reqscript') end,
        mkmodule=function(name) return state:mkmodule(name) end,
    }}).base
    state:set_base(base)
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
end)
