-- TestBed construction configuration validation and freezing.

local M = {}

local DEFAULT_MODULE_ROOTS = {'src/scripts_modinstalled', 'src', '.'}
local DEFAULT_SCRIPT_ROOTS = {'src/scripts_modinstalled'}
local RESERVED_GLOBALS = {
    _G=true, require=true, reqscript=true, mkmodule=true, package=true,
    load=true, loadfile=true, dofile=true, reload=true,
    script_environment=true, dfhack_flags=true,
}
local TOP_LEVEL_FIELDS = {
    module_roots=true, script_roots=true, globals=true,
    component_imports=true, imports=true,
}
local PROVIDER_FIELDS = {
    provide=true, use_value=true, use_source=true, use_host=true,
    use_existing=true,
}
local STRATEGY_FIELDS = {'use_value', 'use_source', 'use_host', 'use_existing'}

---Raises one configuration error with the failing field path.
---@param path string
---@param message string
---@return never
local function invalid(path, message)
    error(('invalid TestBed configuration at %s: %s'):format(path, message), 3)
end

---Returns a read-only proxy over a frozen configuration container.
---@param value table
---@return table
local function freeze(value)
    return setmetatable({}, {
        __index=value,
        __newindex=function()
            error('TestBed normalized configuration is immutable', 2)
        end,
        __pairs=function() return pairs(value) end,
        __len=function() return #value end,
        __metatable=false,
    })
end

---Joins a consumer root and logical child path without claiming containment.
---@param root string
---@param child string
---@return string
local function join_path(root, child)
    if root == '' or root == '.' then return child end
    local separator = package.config:sub(1, 1)
    if root:sub(-1) == '/' or root:sub(-1) == '\\' then return root .. child end
    return root .. separator .. child
end

---Returns whether a path appears to name an existing directory.
---@param path string
---@return boolean
local function directory_exists(path)
    local renamed = os.rename(path, path)
    if not renamed then return false end
    local file = io.open(path, 'rb')
    if file then
        file:close()
        return false
    end
    return true
end

---Owns a copied dense array of strings.
---@class dwarfspec.testbed.StringList
---@field values string[]
local StringList = {}
StringList.__index = StringList

---Copies one dense string array into a StringList.
---@param source any
---@param path string
---@return dwarfspec.testbed.StringList
function StringList.copy(source, path)
    if type(source) ~= 'table' then invalid(path, 'expected an array') end
    local count = 0
    for key in pairs(source) do
        if type(key) ~= 'number' or key < 1 or key % 1 ~= 0 then
            invalid(path, 'expected a dense array')
        end
        count = count + 1
    end
    local values = {}
    for index = 1, count do
        if type(source[index]) ~= 'string' then
            invalid(('%s[%d]'):format(path, index), 'expected a string')
        end
        values[index] = source[index]
    end
    return setmetatable({values=values}, StringList)
end

---Returns a frozen copy of this string list's values.
---@return table
function StringList:freeze()
    return freeze(self.values)
end

---Owns one copied module-or-script import identity.
---@class dwarfspec.testbed.Token
---@field kind dwarfspec.TestBedImportKind
---@field name string
local Token = {}
Token.__index = Token

---Copies and validates one TestBed import token.
---@param source any
---@param path string
---@return dwarfspec.testbed.Token
function Token.copy(source, path)
    if type(source) ~= 'table' then invalid(path, 'expected a token table') end
    for key in pairs(source) do
        if key ~= 'kind' and key ~= 'name' then
            invalid(path .. '.' .. tostring(key), 'unknown token field')
        end
    end
    if source.kind ~= 'module' and source.kind ~= 'script' then
        invalid(path .. '.kind', 'expected "module" or "script"')
    end
    if type(source.name) ~= 'string' then
        invalid(path .. '.name', 'expected a string')
    end
    return setmetatable({kind=source.kind, name=source.name}, Token)
end

---Returns whether another token has this exact namespace and name identity.
---@param other dwarfspec.testbed.Token
---@return boolean
function Token:equals(other)
    return type(other) == 'table' and self.kind == other.kind and
        self.name == other.name
end

---Returns whether another token belongs to this token's namespace.
---@param other dwarfspec.testbed.Token
---@return boolean
function Token:has_same_namespace(other)
    return type(other) == 'table' and self.kind == other.kind
end

---Returns a frozen data-only view of this token.
---@return table
function Token:freeze()
    return freeze({kind=self.kind, name=self.name})
end

---Owns one copied and validated TestBed import provider.
---@class dwarfspec.testbed.Provider
---@field provide dwarfspec.testbed.Token
---@field use_value? any
---@field use_source? string
---@field use_host? true
---@field use_existing? dwarfspec.testbed.Token
local Provider = {}
Provider.__index = Provider

---Copies and validates one provider without copying its borrowed payload.
---@param source any
---@param path string
---@param host_importer function|nil
---@return dwarfspec.testbed.Provider
function Provider.copy(source, path, host_importer)
    if type(source) ~= 'table' then invalid(path, 'expected a provider table') end
    for key in pairs(source) do
        if not PROVIDER_FIELDS[key] then
            invalid(path .. '.' .. tostring(key), 'unknown provider field')
        end
    end
    local provider = setmetatable({provide=Token.copy(source.provide,
        path .. '.provide')}, Provider)
    local selected = nil
    for _, field in ipairs(STRATEGY_FIELDS) do
        if rawget(source, field) ~= nil then
            if selected then invalid(path, 'expected exactly one provider strategy') end
            selected = field
        end
    end
    if not selected then invalid(path, 'expected exactly one provider strategy') end
    if selected == 'use_value' then
        provider.use_value = source.use_value
        if provider.provide.kind == 'script' and type(provider.use_value) ~= 'table' then
            invalid(path .. '.use_value', 'script values must be tables')
        end
    elseif selected == 'use_source' then
        if type(source.use_source) ~= 'string' then
            invalid(path .. '.use_source', 'expected a string')
        end
        provider.use_source = source.use_source
    elseif selected == 'use_host' then
        if source.use_host ~= true then invalid(path .. '.use_host', 'expected true') end
        if type(host_importer) ~= 'function' then
            invalid(path .. '.use_host', 'requires a live host importer')
        end
        provider.use_host = true
    else
        provider.use_existing = Token.copy(source.use_existing,
            path .. '.use_existing')
        if not provider.provide:has_same_namespace(provider.use_existing) then
            invalid(path .. '.use_existing.kind',
                'must use the same namespace as provide')
        end
    end
    if provider.provide.kind == 'module' and provider.provide.name == 'dfhack' then
        invalid(path .. '.provide', 'the module token "dfhack" is reserved')
    end
    return provider
end

---Returns a frozen data-only view of this provider.
---@return table
function Provider:freeze()
    return freeze({provide=self.provide:freeze(), use_value=self.use_value,
        use_source=self.use_source, use_host=self.use_host,
        use_existing=self.use_existing and self.use_existing:freeze() or nil})
end

---Owns an ordered copied provider sequence.
---@class dwarfspec.testbed.ProviderList
---@field items dwarfspec.testbed.Provider[]
local ProviderList = {}
ProviderList.__index = ProviderList

---Copies and validates an ordered provider array.
---@param source any
---@param host_importer function|nil
---@param path string
---@return dwarfspec.testbed.ProviderList
function ProviderList.copy(source, host_importer, path)
    if type(source) ~= 'table' then invalid(path, 'expected an array') end
    local count = 0
    for key in pairs(source) do
        if type(key) ~= 'number' or key < 1 or key % 1 ~= 0 then
            invalid(path, 'expected a dense array')
        end
        count = count + 1
    end
    local items = {}
    for index = 1, count do
        if source[index] == nil then invalid(path, 'expected a dense array') end
        local provider = Provider.copy(source[index],
            ('%s[%d]'):format(path, index), host_importer)
        for earlier = 1, #items do
            if provider.provide:equals(items[earlier].provide) then
                invalid(('%s[%d].provide'):format(path, index),
                    'duplicates an earlier provider token')
            end
        end
        items[index] = provider
    end
    return setmetatable({items=items}, ProviderList)
end

---Returns whether this list contains an exact token identity.
---@param token dwarfspec.testbed.Token
---@return boolean
function ProviderList:contains(token)
    for _, provider in ipairs(self.items) do
        if provider.provide:equals(token) then return true end
    end
    return false
end

---Merges synthesized and user providers with user identities taking precedence.
---@param synthesized dwarfspec.testbed.ProviderList
---@param users dwarfspec.testbed.ProviderList
---@param include_synthesized boolean
---@return dwarfspec.testbed.ProviderList
function ProviderList.merge(synthesized, users, include_synthesized)
    local items = {}
    if include_synthesized then
        for _, provider in ipairs(synthesized.items) do
            if not users:contains(provider.provide) then table.insert(items, provider) end
        end
    end
    for _, provider in ipairs(users.items) do table.insert(items, provider) end
    return setmetatable({items=items}, ProviderList)
end

---Returns frozen provider snapshots in their established order.
---@return table
function ProviderList:freeze()
    local result = {}
    for index, provider in ipairs(self.items) do result[index] = provider:freeze() end
    return freeze(result)
end

---Owns a copied globals container while retaining nested value identities.
---@class dwarfspec.testbed.Globals
---@field values table<string, any>
local Globals = {}
Globals.__index = Globals

---Copies and validates a globals container without copying nested values.
---@param source any
---@return dwarfspec.testbed.Globals
function Globals.copy(source)
    if source == nil then return setmetatable({values={}}, Globals) end
    if type(source) ~= 'table' then invalid('globals', 'expected a table') end
    local values = {}
    for key, value in pairs(source) do
        if type(key) ~= 'string' then invalid('globals', 'expected string keys') end
        if RESERVED_GLOBALS[key] then
            invalid('globals.' .. key, 'reserved TestBed loader binding')
        end
        if key == 'dfhack' and type(value) ~= 'table' then
            invalid('globals.dfhack', 'expected a table')
        end
        values[key] = value
    end
    return setmetatable({values=values}, Globals)
end

---Returns a frozen globals-container snapshot.
---@return table
function Globals:freeze()
    return freeze(self.values)
end

---Owns a lookup table for exact immutable provider identities.
---@class dwarfspec.testbed.ProviderRegistry
---@field module table<string, table>
---@field script table<string, table>
local ProviderRegistry = {}
ProviderRegistry.__index = ProviderRegistry

---Constructs a provider registry from one already-merged provider list.
---@param providers dwarfspec.testbed.ProviderList
---@return dwarfspec.testbed.ProviderRegistry
function ProviderRegistry.new(providers)
    local registry = setmetatable({module={}, script={}}, ProviderRegistry)
    for _, provider in ipairs(providers.items) do
        registry[provider.provide.kind][provider.provide.name] = provider:freeze()
    end
    return registry
end

---Returns the frozen registry view.
---@return table
function ProviderRegistry:freeze()
    return freeze({module=freeze(self.module), script=freeze(self.script)})
end

---Filters default roots while retaining the complete attempted order.
---@param roots dwarfspec.testbed.StringList
---@param configured boolean
---@param consumer_root string
---@param exists fun(path: string): boolean
---@return dwarfspec.testbed.StringList, dwarfspec.testbed.StringList
local function select_roots(roots, configured, consumer_root, exists)
    local effective, attempted = {}, {}
    for _, root in ipairs(roots.values) do
        table.insert(attempted, root)
        if configured or exists(join_path(consumer_root, root)) then
            table.insert(effective, root)
        end
    end
    return StringList.copy(effective, 'internal effective roots'),
        StringList.copy(attempted, 'internal attempted roots')
end

---Normalizes one private TestBed construction request.
---The caller supplies live-only capabilities through `options`; they are never
---accepted from the public configuration. Containers become immutable snapshots
---while `use_value` and nested global values retain their borrowed identities.
---@param config? dwarfspec.TestBedConfig
---@param options? table
---@return table
function M.normalize(config, options)
    if config == nil then config = {} end
    if type(config) ~= 'table' then invalid('config', 'expected a table') end
    options = options or {}
    if type(options) ~= 'table' then error('TestBed normalization options must be a table', 2) end
    for key in pairs(config) do
        if not TOP_LEVEL_FIELDS[key] then
            invalid('config.' .. tostring(key), 'unknown configuration field')
        end
    end
    local profile = options.profile or 'standalone'
    if profile ~= 'standalone' and profile ~= 'mount' then
        error('TestBed normalization profile must be "standalone" or "mount"', 2)
    end
    local consumer_root = options.consumer_root or '.'
    if type(consumer_root) ~= 'string' then
        error('TestBed normalization consumer_root must be a string', 2)
    end
    local host_importer = options.host_importer
    if host_importer ~= nil and type(host_importer) ~= 'function' then
        error('TestBed normalization host_importer must be a function', 2)
    end
    local roots_exist = options.directory_exists or directory_exists
    if type(roots_exist) ~= 'function' then
        error('TestBed normalization directory_exists must be a function', 2)
    end
    local component_imports = config.component_imports
    if component_imports == nil then component_imports = profile == 'mount' end
    if type(component_imports) ~= 'boolean' then
        invalid('config.component_imports', 'expected a boolean')
    end
    if component_imports and type(host_importer) ~= 'function' then
        invalid('config.component_imports', 'requires a live host importer')
    end
    local module_input = config.module_roots == nil and DEFAULT_MODULE_ROOTS or
        config.module_roots
    local script_input = config.script_roots == nil and DEFAULT_SCRIPT_ROOTS or
        config.script_roots
    local module_selection, attempted_module_selection = select_roots(
        StringList.copy(module_input, 'config.module_roots'),
        config.module_roots ~= nil, consumer_root, roots_exist)
    local script_selection, attempted_script_selection = select_roots(
        StringList.copy(script_input, 'config.script_roots'),
        config.script_roots ~= nil, consumer_root, roots_exist)
    local users = ProviderList.copy(config.imports == nil and {} or config.imports,
        host_importer, 'config.imports')
    local synthesized = ProviderList.copy(
        options.synthesized_providers == nil and {} or
            options.synthesized_providers,
        host_importer, 'options.synthesized_providers')
    local providers = ProviderList.merge(synthesized, users, component_imports)
    local registry = ProviderRegistry.new(providers)
    return freeze({
        profile=profile, consumer_root=consumer_root, host_importer=host_importer,
        component_imports=component_imports,
        module_roots=module_selection:freeze(),
        script_roots=script_selection:freeze(),
        attempted_module_roots=attempted_module_selection:freeze(),
        attempted_script_roots=attempted_script_selection:freeze(),
        globals=Globals.copy(config.globals):freeze(), imports=providers:freeze(),
        provider_registry=registry:freeze(),
    })
end

return M
