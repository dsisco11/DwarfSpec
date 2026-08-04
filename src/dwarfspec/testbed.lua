-- Framework-neutral public TestBed entry point.

---@alias dwarfspec.TestBedImportKind
---| '"module"'
---| '"script"'

---Identifies one exact TestBed dependency.
---@class (exact) dwarfspec.TestBedImportToken
---@field kind dwarfspec.TestBedImportKind
---@field name string

---Identifies a Lua value that can be present in a provider table.
---@alias dwarfspec.TestBedNonNilValue boolean|number|string|function|table|thread|userdata

---Provides one exact borrowed value.
---@class (exact) dwarfspec.TestBedValueImport
---@field provide dwarfspec.TestBedImportToken
---@field use_value dwarfspec.TestBedNonNilValue

---Provides one exact source file loaded by the TestBed.
---@class (exact) dwarfspec.TestBedSourceImport
---@field provide dwarfspec.TestBedImportToken
---@field use_source string

---Borrows one exact module or script from the live host.
---@class (exact) dwarfspec.TestBedHostImport
---@field provide dwarfspec.TestBedImportToken
---@field use_host true

---Aliases one exact token in the same namespace.
---@class (exact) dwarfspec.TestBedExistingImport
---@field provide dwarfspec.TestBedImportToken
---@field use_existing dwarfspec.TestBedImportToken

---@alias dwarfspec.TestBedImport
---| dwarfspec.TestBedValueImport
---| dwarfspec.TestBedSourceImport
---| dwarfspec.TestBedHostImport
---| dwarfspec.TestBedExistingImport

---Provides additional runtime globals and the optional DFHack API backing mock.
---@class (exact) dwarfspec.TestBedGlobals: table<string, any>
---@field dfhack? table

---Configures module and script resolution for one TestBed.
---@class (exact) dwarfspec.TestBedConfig
---@field module_roots? string[]
---@field globals? dwarfspec.TestBedGlobals
---@field component_imports? boolean
---@field imports? dwarfspec.TestBedImport[]
---@field script_roots? string[]

---Owns one bed-local module and script graph.
---@class dwarfspec.TestBed
---@field private _guard table
---@field private _package_state dwarfspec.testbed.PackageState|nil
---@field private _script_loader dwarfspec.testbed.ScriptLoader|nil
local TestBed = {}
TestBed.__index = TestBed

---Returns whether a value is an instantiated TestBed.
---@param value any
---@return boolean
function TestBed.is_instance(value)
    return type(value) == 'table' and getmetatable(value) == TestBed and
        type(rawget(value, '_guard')) == 'table'
end

---Raises the shared closed-TestBed error before accessing private state.
---@param self dwarfspec.TestBed
local function ensure_open(self)
    if self._guard.closed then error('TestBed is closed', 2) end
end

---Creates a bed-local module environment from a typed configuration.
---The future instance owns its graph and copies configuration containers, while
---values supplied by `use_value` and nested global values remain borrowed.
---@param config? dwarfspec.TestBedConfig
---@return dwarfspec.TestBed
function TestBed.new(config)
    return require('dwarfspec.testbed.internal').new(TestBed, config)
end

---Loads one Lua module through this TestBed.
---The graph remains owned by this TestBed; failures leave no public diagnostic
---object, and the loader-data result is available only on Lua versions that
---return it from a searcher invocation.
---@param name string
---@return any value
---@return any? loader_data
function TestBed:require(name)
    ensure_open(self)
    return self._package_state:require(name)
end

---Loads one annotated DFHack script module through this TestBed.
---The returned table belongs to the bed-local graph and failures retain TestBed
---ownership of partial loader state until `close` completes.
---@param name string
---@return table
function TestBed:reqscript(name)
    ensure_open(self)
    return self._script_loader:reqscript(name)
end

---Closes this TestBed and releases its owned graph.
---Borrowed values are not mutated or released, and this operation returns no
---graph, inspection, or diagnostic object.
function TestBed:close()
    if self._guard.closed then return end
    self._guard.closed = true
    self._script_loader:close()
    self._package_state:close()
    self._script_loader, self._package_state = nil, nil
end

return TestBed
