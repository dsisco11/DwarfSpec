-- TestBed-private Lua package state and module loader.

local ModuleEnvironment = require('dwarfspec.testbed.base_environment').ModuleEnvironment

local M = {}

---Limits retained diagnostic text without preserving arbitrary source paths.
---@type integer
local MAX_CHAIN_LENGTH = 16

---Limits retained source-selection text in private loader diagnostics.
---@type integer
local MAX_RECORD_TEXT_LENGTH = 160

---Returns one bounded logical dependency chain.
---@param chain string[]
---@param name string
---@return string
local function format_chain(chain, name)
    local values, first = {}, math.max(1, #chain - MAX_CHAIN_LENGTH + 2)
    if first > 1 then table.insert(values, '...') end
    for index = first, #chain do table.insert(values, chain[index]) end
    if name ~= '' then table.insert(values, name) end
    return table.concat(values, ' -> ')
end

---Returns a bounded diagnostic fragment without retaining caller-owned values.
---@param value any
---@return string|nil
local function bounded_text(value)
    if type(value) ~= 'string' then return nil end
    if #value <= MAX_RECORD_TEXT_LENGTH then return value end
    return value:sub(1, MAX_RECORD_TEXT_LENGTH - 3) .. '...'
end

---Returns a native-compatible private preload search failure.
---@param name string
---@return string
local function preload_error(name)
    return "\n\tno field package.preload['" .. name .. "']"
end

---Owns mutable package tables and private source-loader state for one bed.
---@class dwarfspec.testbed.PackageState
---@field package table
---@field loaded table<string, any>
---@field preload table<string, function>
---@field active table<string, boolean>
---@field chain string[]
---@field record table|nil
---@field normalized table
---@field paths dwarfspec.testbed.Paths
---@field base table|nil
---@field script_loader dwarfspec.testbed.ScriptLoader|nil
---@field loadfile fun(filename: string, mode?: string, environment?: table): function|nil, string|nil
---@field guard table
local PackageState = {}
PackageState.__index = PackageState

---Constructs private package tables before the owning base environment exists.
---@param normalized table
---@param paths dwarfspec.testbed.Paths
---@param guard table
---@param options? table
---@return dwarfspec.testbed.PackageState
function PackageState.new(normalized, paths, guard, options)
    assert(type(normalized) == 'table', 'TestBed package state requires normalized configuration')
    assert(type(paths) == 'table', 'TestBed package state requires paths')
    options = options or {}
    assert(type(options) == 'table', 'TestBed package state options must be a table')
    local compile_file = options.loadfile or loadfile
    assert(type(compile_file) == 'function', 'TestBed package state loadfile must be a function')
    local loaded, preload = {}, {}
    assert(type(guard) == 'table', 'TestBed package state requires a close guard')
    local state = setmetatable({loaded=loaded, preload=preload, active={}, chain={}, guard=guard,
        normalized=normalized, paths=paths, loadfile=compile_file}, PackageState)
    local private_package = {loaded=loaded, preload=preload, path=paths.package_path,
        config=package.config}
    private_package.searchpath = function(name, path, separator, replacement)
        return paths:searchpath(name, path, separator, replacement)
    end
    private_package.searchers = {
        function(name) return state:search_preload(name) end,
        function(name) return state:search_provider(name) end,
        function(name) return state:search_source(name) end,
    }
    state.package = private_package
    return state
end

---Raises the shared closed-TestBed error before accessing retained graph state.
function PackageState:ensure_open()
    if self.guard.closed then error('TestBed is closed', 2) end
end

---Clears private graph references while retaining only the shared close guard.
function PackageState:close()
    for key in pairs(self.loaded) do self.loaded[key] = nil end
    for key in pairs(self.preload) do self.preload[key] = nil end
    self.active, self.chain, self.record = {}, {}, nil
    self.normalized, self.paths, self.base, self.script_loader, self.package, self.loadfile =
        nil, nil, nil, nil, nil, nil
end

---Attaches the stable base facade used by subsequently compiled module environments.
---@param base table
function PackageState:set_base(base)
    self:ensure_open()
    assert(type(base) == 'table', 'TestBed package state base must be a table')
    assert(self.base == nil, 'TestBed package state base is already attached')
    self.base = base
end

---Installs the one bed-local script loader used by source module environments.
---@param loader dwarfspec.testbed.ScriptLoader
function PackageState:set_script_loader(loader)
    self:ensure_open()
    assert(type(loader) == 'table', 'TestBed script loader must be a table')
    assert(self.script_loader == nil, 'TestBed script loader is already attached')
    self.script_loader = loader
end

---Loads one annotated script through the installed private script loader.
---@param name string
---@return table
function PackageState:reqscript(name)
    self:ensure_open()
    assert(self.script_loader ~= nil, 'TestBed script loader is not attached')
    return self.script_loader:reqscript(name)
end

---Returns the bed-local dfhack facade without consulting mutable package state.
---@return table
function PackageState:dfhack()
    self:ensure_open()
    assert(self.base ~= nil, 'TestBed package state base is not attached')
    return self.base.dfhack
end

---Searches the authoritative private preload table.
---@param name string
---@return function|string
function PackageState:search_preload(name)
    self:ensure_open()
    local loader = self.preload[name]
    if loader ~= nil then
        if type(loader) ~= 'function' then
            error(('TestBed package.preload[%q] must be a function'):format(name), 2)
        end
        return loader, ':preload:'
    end
    return preload_error(name)
end

---Builds a loader-data string for one exact provider token.
---@param strategy string
---@param name string
---@return string
local function provider_data(strategy, name)
    return (':testbed:%s:module:%s'):format(strategy, name)
end

---Wraps one provider loader with its exact token, strategy, and ownership context.
---@param name string
---@param strategy string
---@param borrowed_host boolean
---@param loader function
---@return function
function PackageState:provider_loader(name, strategy, borrowed_host, loader)
    return function(...)
        local arguments = table.pack(...)
        local results = table.pack(xpcall(function()
            return loader(table.unpack(arguments, 1, arguments.n))
        end,
            function(message) return message end))
        if not results[1] then
            local ownership = borrowed_host and ', borrowed host value' or ''
            error(('TestBed module provider %q (%s%s) failed: %s'):format(name,
                strategy, ownership, tostring(results[2])), 0)
        end
        return table.unpack(results, 2, results.n)
    end
end

---Searches immutable module providers before mutable source paths.
---@param name string
---@return function|string
function PackageState:search_provider(name)
    self:ensure_open()
    local provider = self.normalized.provider_registry.module[name]
    if provider == nil then return "\n\tno TestBed provider for module '" .. name .. "'" end
    if provider.use_value ~= nil or provider.use_value == false then
        return self:provider_loader(name, 'use_value', false,
            function() return provider.use_value end), provider_data('use_value', name)
    end
    if provider.use_existing ~= nil then
        local target = provider.use_existing.name
        return self:provider_loader(name, 'use_existing', false,
            function() return self:require(target) end), provider_data('use_existing', name)
    end
    if provider.use_host then
        return self:provider_loader(name, 'use_host', true,
            function() return self.normalized.host_importer('module', name) end),
            provider_data('use_host', name)
    end
    local filename = self.paths:resolve_source(provider.use_source)
    return self:provider_loader(name, 'use_source', false,
        self:source_loader(filename)), filename
end

---Creates one loader that compiles a source file inside a fresh owning environment.
---@param filename string
---@return function
function PackageState:source_loader(filename)
    return function()
        self:ensure_open()
        assert(self.base ~= nil, 'TestBed package state base is not attached')
        local environment = ModuleEnvironment.new(self.base, {package=self.package,
            require=function(name) return self:require(name) end,
            reqscript=function(name) return self:reqscript(name) end,
            mkmodule=function(name) return self:mkmodule(name) end,
            ensure_open=function() return self:ensure_open() end,
            loadfile=self.loadfile,
        })
        local chunk, message = environment.values.loadfile(filename)
        if not chunk then error(message, 0) end
        return chunk()
    end
end

---Searches the mutable private Lua source path.
---@param name string
---@return function|string
function PackageState:search_source(name)
    self:ensure_open()
    local filename, message = self.paths:searchpath(name, self.package.path)
    if not filename then return message end
    return self:source_loader(filename), filename
end

---Loads one non-reserved module with bounded dependency-cycle detection.
---@param name string
---@return any value
---@return any? loader_data
function PackageState:require(name)
    self:ensure_open()
    if type(name) ~= 'string' then error('TestBed require name must be a string', 2) end
    if name == 'dfhack' then return self:dfhack() end
    local cached = self.loaded[name]
    if cached ~= nil and cached ~= false then return cached end
    if self.active[name] then
        error('TestBed circular require: ' .. format_chain(self.chain, name), 2)
    end
    self.active[name] = true
    table.insert(self.chain, name)
    local function perform()
        local errors = {}
        local searchers = self.package.searchers
        local index = 1
        while true do
            local searcher = searchers[index]
            if searcher == nil then break end
            if type(searcher) ~= 'function' then
                error(('TestBed package.searchers[%d] must be a function'):format(index), 0)
            end
            local loader, data = searcher(name)
            if type(loader) == 'function' then
                local record = {name=bounded_text(name), loader_data=bounded_text(data)}
                self.record = record
                local result = loader(name, data)
                if result ~= nil then self.loaded[name] = result end
                if self.loaded[name] == nil then self.loaded[name] = true end
                record.result_type = type(self.loaded[name])
                record.borrowed_host = type(data) == 'string' and
                    data:find(':testbed:use_host:module:', 1, true) == 1 or nil
                self.record = record
                return self.loaded[name], data
            end
            if type(loader) ~= 'string' then
                error(('TestBed package.searchers[%d] must return a loader or error string'):format(index), 0)
            end
            table.insert(errors, loader)
            index = index + 1
        end
        error(('module %q not found:%s\n\tTestBed dependency chain: %s'):format(name,
            table.concat(errors), format_chain(self.chain, '')), 0)
    end
    local results = table.pack(xpcall(perform, function(message) return message end))
    self.active[name] = nil
    table.remove(self.chain)
    if not results[1] then error(results[2], 2) end
    return results[2], results[3]
end

---Creates or returns a stable bed-local module environment and publishes it immediately.
---@param name string
---@return table
function PackageState:mkmodule(name)
    self:ensure_open()
    if type(name) ~= 'string' then error('TestBed mkmodule name must be a string', 2) end
    local existing = self.loaded[name]
    if existing ~= nil and existing ~= false then return existing end
    assert(self.base ~= nil, 'TestBed package state base is not attached')
    local environment = ModuleEnvironment.new(self.base, {package=self.package,
        require=function(module_name) return self:require(module_name) end,
        reqscript=function(script_name) return self:reqscript(script_name) end,
        mkmodule=function(module_name) return self:mkmodule(module_name) end,
        ensure_open=function() return self:ensure_open() end,
    })
    self.loaded[name] = environment.values
    return environment.values
end

M.PackageState = PackageState

return M
