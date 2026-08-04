-- Driver-side construction adapter for TestBed-backed component descriptors.

local M = {}

---Declares the installed DFHack release supported by synthesized imports.
---@type string
M.SUPPORTED_DFHACK_VERSION = '53.15-r2'

---Maps each supported DFHack release to its exact component-import modules.
---@type table<string, string[]>
M.COMPONENT_IMPORTS_BY_VERSION = {
    ['53.15-r2']={'class', 'utils', 'gui', 'gui.widgets', 'gui.dwarfmode'},
}

---Returns the exact supported component-import module names.
---@return string[]
local function component_modules()
    return assert(M.COMPONENT_IMPORTS_BY_VERSION[M.SUPPORTED_DFHACK_VERSION],
        'TestBed adapter has no component imports for its supported DFHack version')
end

---Builds the documented synthesized component-import provider set.
---@return table
local function synthesized_providers()
    local providers = {}
    for _, name in ipairs(component_modules()) do
        table.insert(providers, {provide={kind='module', name=name}, use_host=true})
    end
    return providers
end

---Validates the live driver inputs used for one TestBed construction.
---@param run table
---@param host table
local function validate_inputs(run, host)
    assert(type(run) == 'table', 'TestBed adapter requires an active run')
    assert(type(run.project_root) == 'string' and run.project_root ~= '',
        'TestBed adapter requires the active run project root')
    assert(type(host) == 'table', 'TestBed adapter requires live host inputs')
    assert(type(host.require) == 'function',
        'TestBed adapter requires the exact host require function')
    assert(type(host.reqscript) == 'function',
        'TestBed adapter requires the exact host reqscript function')
    assert(type(host.base) == 'table',
        'TestBed adapter requires the raw dfhack.BASE_G table')
    assert(type(host.dfhack) == 'table', 'TestBed adapter requires dfhack')
end

---Constructs one live TestBed from the active run and explicit host functions.
---Host import calls retain their normal process-cache behavior; this adapter
---does not attempt to isolate, clear, or report those host-owned caches.
---@param config dwarfspec.TestBedConfig|nil
---@param run table
---@param host table
---@param loader_options? table
---@return dwarfspec.TestBed
function M.new(config, run, host, loader_options)
    validate_inputs(run, host)
    loader_options = loader_options or {}
    assert(type(loader_options) == 'table', 'TestBed adapter loader options must be a table')
    local TestBed = require('dwarfspec.testbed')
    local internal = require('dwarfspec.testbed.internal')
    return internal.new(TestBed, config, {profile='mount',
        consumer_root=run.project_root,
        current_directory=loader_options.current_directory,
        directory_exists=loader_options.directory_exists,
        file_exists=loader_options.file_exists,
        read_source=loader_options.read_source,
        load_chunk=loader_options.load_chunk,
        loadfile=loader_options.loadfile,
        host_importer=function(kind, name)
            if kind == 'module' then return host.require(name) end
            assert(kind == 'script', 'TestBed adapter received an invalid import kind')
            return host.reqscript(name)
        end,
        host_base=host.base,
        host_dfhack=host.dfhack,
        synthesized_providers=synthesized_providers(),
    })
end

M.COMPONENT_MODULES = component_modules()

return M
