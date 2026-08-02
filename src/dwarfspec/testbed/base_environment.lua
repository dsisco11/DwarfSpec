-- TestBed-private base environment and DFHack facade construction.

local M = {}

---Defines loader-owned keys for the supported DFHack import surface.
---Each key is installed by TestBed or explicitly rejected so it cannot fall
---through to a later host addition.
---@class dwarfspec.testbed.ReservedLoaderPolicy
---@field base table<string, boolean>
---@field dfhack table<string, boolean>
local RESERVED_POLICY = {
    base={_G=true, package=true, require=true, reqscript=true, mkmodule=true,
        load=true, loadfile=true, dofile=true, reload=true,
        script_environment=true, dfhack_flags=true, dfhack=true},
    dfhack={BASE_G=true, reqscript=true, reload=true, script_environment=true},
}

local STANDARD_NAMES = {
    '_VERSION', 'assert', 'collectgarbage', 'error', 'getmetatable', 'ipairs',
    'next', 'pairs', 'pcall', 'print', 'rawequal', 'rawget', 'rawlen',
    'rawset', 'select', 'setmetatable', 'tonumber', 'tostring', 'type',
    'xpcall', 'coroutine', 'debug', 'io', 'math', 'os', 'string', 'table',
    'utf8',
}

---Raises a consistent unsupported-loader operation error.
---@param name string
---@return never
local function unsupported(name)
    error(('TestBed %s is unavailable in this environment'):format(name), 2)
end

---Returns a rejecting closure for one loader operation that is not bound yet.
---@param name string
---@return fun(...): never
local function rejecting_loader(name)
    return function()
        return unsupported(name)
    end
end

---Copies only the documented standard Lua globals from the current interpreter.
---@return table<string, any>
local function standard_bindings()
    local bindings = {}
    for _, name in ipairs(STANDARD_NAMES) do bindings[name] = _G[name] end
    if _G.warn ~= nil then bindings.warn = _G.warn end
    return bindings
end

---Creates a shallow ordinary-API snapshot without retaining a mutable host table.
---@param source table
---@return table
local function snapshot(source)
    local result = {}
    for key, value in pairs(source) do result[key] = value end
    return result
end

---Returns whether a key is protected in one facade category.
---@param category 'base'|'dfhack'
---@param key any
---@return boolean
local function is_reserved(category, key)
    return type(key) == 'string' and RESERVED_POLICY[category][key] == true
end

---Owns one stable base environment and DFHack facade pair for a TestBed.
---@class dwarfspec.testbed.BaseEnvironment
---@field base table
---@field dfhack table
---@field base_backing table<string, any>
---@field dfhack_backing table<string, any>
local BaseEnvironment = {}
BaseEnvironment.__index = BaseEnvironment

---Constructs the facade pair from normalized configuration and injected host state.
---@param normalized table
---@param options? table
---@return dwarfspec.testbed.BaseEnvironment
function BaseEnvironment.new(normalized, options)
    assert(type(normalized) == 'table', 'TestBed base environment requires normalized configuration')
    options = options or {}
    assert(type(options) == 'table', 'TestBed base environment options must be a table')
    local loaders = options.loaders or {}
    assert(type(loaders) == 'table', 'TestBed base environment loaders must be a table')
    local host_base = options.host_base
    if host_base ~= nil then assert(type(host_base) == 'table', 'TestBed host base must be a table') end
    local host_dfhack = options.host_dfhack
    if host_dfhack ~= nil then assert(type(host_dfhack) == 'table', 'TestBed host dfhack must be a table') end

    local base_backing = standard_bindings()
    if host_base then
        for key, value in pairs(host_base) do
            if not is_reserved('base', key) then base_backing[key] = value end
        end
    end
    for key, value in pairs(normalized.globals) do
        if key ~= 'dfhack' then base_backing[key] = value end
    end
    local dfhack_backing = snapshot(normalized.globals.dfhack or host_dfhack or {})
    local environment = setmetatable({base_backing=base_backing,
        dfhack_backing=dfhack_backing}, BaseEnvironment)

    local base, dfhack = {}, {}
    environment.base, environment.dfhack = base, dfhack

    ---Returns the visible facade value without exposing protected backing slots.
    ---@param backing table
    ---@param category 'base'|'dfhack'
    ---@param key any
    ---@return any
    local function read(backing, category, key)
        if category == 'base' and key == 'dfhack' then return dfhack end
        if category == 'dfhack' and key == 'BASE_G' then return base end
        if is_reserved(category, key) then return backing[key] end
        return backing[key]
    end

    ---Writes an ordinary facade value while rejecting loader-owned keys.
    ---@param backing table
    ---@param category 'base'|'dfhack'
    ---@param key any
    ---@param value any
    ---@return table
    local function write(backing, category, key, value)
        if is_reserved(category, key) then
            error(('TestBed %s.%s is loader-owned'):format(category, tostring(key)), 3)
        end
        backing[key] = value
        return backing
    end

    ---Returns raw facade state while respecting loader-owned facade values.
    ---@param value any
    ---@param key any
    ---@return any
    local function rawget_wrapper(value, key)
        if value == base then return read(base_backing, 'base', key) end
        if value == dfhack then return read(dfhack_backing, 'dfhack', key) end
        return rawget(value, key)
    end

    ---Writes facade backing state while preserving reserved loader protections.
    ---@param value any
    ---@param key any
    ---@param replacement any
    ---@return any
    local function rawset_wrapper(value, key, replacement)
        if value == base then write(base_backing, 'base', key, replacement); return base end
        if value == dfhack then write(dfhack_backing, 'dfhack', key, replacement); return dfhack end
        return rawset(value, key, replacement)
    end

    ---Advances facade iteration over its backing table.
    ---@param value any
    ---@param key any
    ---@return any, any
    local function next_wrapper(value, key)
        if value == base then return next(base_backing, key) end
        if value == dfhack then return next(dfhack_backing, key) end
        return next(value, key)
    end

    ---Returns an iterator over facade backing state or native pairs behavior.
    ---@param value any
    ---@return fun(table, any):any, table, any
    local function pairs_wrapper(value)
        if value == base then return next, base_backing, nil end
        if value == dfhack then return next, dfhack_backing, nil end
        return pairs(value)
    end

    base_backing.rawget = rawget_wrapper
    base_backing.rawset = rawset_wrapper
    base_backing.next = next_wrapper
    base_backing.pairs = pairs_wrapper
    base_backing.package = loaders.package or {}
    base_backing.require = loaders.require or rejecting_loader('require')
    base_backing.reqscript = loaders.reqscript or rejecting_loader('reqscript')
    base_backing.mkmodule = loaders.mkmodule or rejecting_loader('mkmodule')
    base_backing.load = loaders.load or rejecting_loader('load')
    base_backing.loadfile = loaders.loadfile or rejecting_loader('loadfile')
    base_backing.dofile = loaders.dofile or rejecting_loader('dofile')
    base_backing.reload = rejecting_loader('reload')
    base_backing.script_environment = rejecting_loader('script_environment')
    base_backing.dfhack_flags = nil
    dfhack_backing.reqscript = base_backing.reqscript
    dfhack_backing.reload = rejecting_loader('dfhack.reload')
    dfhack_backing.script_environment = rejecting_loader('dfhack.script_environment')

    setmetatable(base, {__index=function(_, key) return read(base_backing, 'base', key) end,
        __newindex=function(_, key, value) write(base_backing, 'base', key, value) end,
        __metatable=false})
    setmetatable(dfhack, {__index=function(_, key) return read(dfhack_backing, 'dfhack', key) end,
        __newindex=function(_, key, value) write(dfhack_backing, 'dfhack', key, value) end,
        __metatable=false})
    return environment
end

M.BaseEnvironment = BaseEnvironment
M.RESERVED_POLICY = RESERVED_POLICY

return M
