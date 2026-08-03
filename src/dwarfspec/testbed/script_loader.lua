-- TestBed-private annotated DFHack script loader.

local ModuleEnvironment = require('dwarfspec.testbed.base_environment').ModuleEnvironment

local M = {}

---Limits retained script dependency chains in failure diagnostics.
---@type integer
local MAX_CHAIN_LENGTH = 16

---Returns a bounded logical script dependency chain.
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

---Validates the modern module annotation before a script executes.
---@param filename string
---@param text string
local function validate_annotation(filename, text)
    if text:find('moduleMode', 1, true) then
        error('TestBed scripts support only the modern --@ module=true annotation', 2)
    end
    if not text:match('^%s*%-%-@%s*module%s*=%s*true') then
        error('TestBed script requires the modern --@ module=true annotation', 2)
    end
end

---Owns the separate script namespace for one TestBed package state.
---@class dwarfspec.testbed.ScriptLoader
---@field package_state dwarfspec.testbed.PackageState
---@field scripts table<string, table>
---@field active table<string, boolean>
---@field chain string[]
---@field loadfile fun(filename: string, mode?: string, environment?: table): function|nil, string|nil
local ScriptLoader = {}
ScriptLoader.__index = ScriptLoader

---Constructs and installs one bed-local script loader.
---@param package_state dwarfspec.testbed.PackageState
---@param options? table
---@return dwarfspec.testbed.ScriptLoader
function ScriptLoader.new(package_state, options)
    assert(type(package_state) == 'table', 'TestBed script loader requires package state')
    options = options or {}
    assert(type(options) == 'table', 'TestBed script loader options must be a table')
    local read_source = options.read_source or function(filename)
        local file = assert(io.open(filename, 'rb'),
            'TestBed could not read script ' .. filename)
        local text = file:read('*a')
        file:close()
        return text
    end
    local load_chunk = options.load_chunk or function(filename, environment)
        return environment.loadfile(filename)
    end
    local compile_file = options.loadfile or loadfile
    assert(type(read_source) == 'function', 'TestBed script loader read_source must be a function')
    assert(type(load_chunk) == 'function', 'TestBed script loader load_chunk must be a function')
    assert(type(compile_file) == 'function', 'TestBed script loader loadfile must be a function')
    local loader = setmetatable({package_state=package_state, scripts={}, active={}, chain={},
        read_source=read_source, load_chunk=load_chunk, loadfile=compile_file}, ScriptLoader)
    package_state:set_script_loader(loader)
    return loader
end

---Builds one script provider loader with actionable ownership context.
---@param name string
---@param strategy string
---@param borrowed_host boolean
---@param callback function
---@return function
function ScriptLoader:provider_loader(name, strategy, borrowed_host, callback)
    return function()
        local results = table.pack(xpcall(callback, function(message) return message end))
        if not results[1] then
            local ownership = borrowed_host and ', borrowed host value' or ''
            error(('TestBed script provider %q (%s%s) failed: %s'):format(name,
                strategy, ownership, tostring(results[2])), 0)
        end
        return table.unpack(results, 2, results.n)
    end
end

---Returns the exact script provider result or nil when none was configured.
---@param name string
---@return function|nil
function ScriptLoader:provider(name)
    self.package_state:ensure_open()
    local provider = self.package_state.normalized.provider_registry.script[name]
    if provider == nil then return nil end
    if provider.use_value ~= nil then
        return self:provider_loader(name, 'use_value', false, function() return provider.use_value end)
    end
    if provider.use_existing ~= nil then
        return self:provider_loader(name, 'use_existing', false,
            function() return self:reqscript(provider.use_existing.name) end)
    end
    if provider.use_host then
        return self:provider_loader(name, 'use_host', true,
            function() return self.package_state.normalized.host_importer('script', name) end)
    end
    local filename = self.package_state.paths:resolve_source(provider.use_source)
    return self:provider_loader(name, 'use_source', false,
        function() return self:load_source(name, filename) end)
end

---Allocates, publishes, and executes one annotated source script environment.
---@param name string
---@param filename string
---@return table
function ScriptLoader:load_source(name, filename)
    self.package_state:ensure_open()
    validate_annotation(filename, self.read_source(filename))
    local state = self.package_state
    local environment = ModuleEnvironment.new(state.base, {package=state.package,
        require=function(module_name) return state:require(module_name) end,
        reqscript=function(script_name) return self:reqscript(script_name) end,
        mkmodule=function(module_name) return state:mkmodule(module_name) end,
        ensure_open=function() return state:ensure_open() end,
        loadfile=self.loadfile,
    })
    rawset(environment.values, 'dfhack_flags', {module=true})
    self.scripts[name] = environment.values
    local chunk, message = self.load_chunk(filename, environment.values)
    if not chunk then error(message, 0) end
    chunk()
    return environment.values
end

---Loads one script through the bed-local script cache and exact provider registry.
---@param name string
---@return table
function ScriptLoader:reqscript(name)
    self.package_state:ensure_open()
    if type(name) ~= 'string' then error('TestBed reqscript name must be a string', 2) end
    local cached = self.scripts[name]
    if cached ~= nil then return cached end
    if self.active[name] then
        error('TestBed circular reqscript: ' .. format_chain(self.chain, name), 2)
    end
    self.active[name] = true
    table.insert(self.chain, name)
    local success, value = xpcall(function()
        local loader = self:provider(name)
        if loader then
            local result = loader()
            self.scripts[name] = result
            return result
        end
        local filename, message = self.package_state.paths:find_script(name)
        if not filename then
            error(('TestBed script %q was not found: %s\n\tTestBed script dependency chain: %s'):
                format(name, message, format_chain(self.chain, '')), 0)
        end
        return self:load_source(name, filename)
    end, function(message) return message end)
    self.active[name] = nil
    table.remove(self.chain)
    if not success then
        self.scripts[name] = nil
        error(value, 2)
    end
    return value
end

---Clears script cache references after the owning TestBed has closed.
function ScriptLoader:close()
    for key in pairs(self.scripts) do self.scripts[key] = nil end
    self.active, self.chain, self.package_state = {}, {}, nil
    self.read_source, self.load_chunk, self.loadfile = nil, nil, nil
end

M.ScriptLoader = ScriptLoader

return M
