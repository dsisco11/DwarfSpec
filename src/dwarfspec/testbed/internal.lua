-- TestBed-private construction implementation.

local M = {}

---Constructs a TestBed instance from validated private construction inputs.
---Live-host capabilities are accepted only through `options`, leaving the
---public TestBed constructor framework-neutral.
---@param TestBed dwarfspec.TestBed
---@param config? dwarfspec.TestBedConfig
---@param options? table
---@return dwarfspec.TestBed
function M.new(TestBed, config, options)
    assert(type(TestBed) == 'table', 'TestBed internal constructor requires the TestBed class')
    local normalize = require('dwarfspec.testbed.config').normalize
    local Paths = require('dwarfspec.testbed.paths').Paths
    local PackageState = require('dwarfspec.testbed.package_state').PackageState
    local BaseEnvironment = require('dwarfspec.testbed.base_environment').BaseEnvironment
    local ScriptLoader = require('dwarfspec.testbed.script_loader').ScriptLoader
    local guard = {closed=false}
    options = options or {}
    local normalized = normalize(config, options)
    local paths = Paths.new(normalized)
    local state = PackageState.new(normalized, paths, guard)
    local base = BaseEnvironment.new(normalized, {host_base=options.host_base,
        host_dfhack=options.host_dfhack, loaders={package=state.package,
        require=function(name) return state:require(name) end,
        reqscript=function(name) return state:reqscript(name) end,
        mkmodule=function(name) return state:mkmodule(name) end,
        ensure_open=function() return state:ensure_open() end,
    }}).base
    state:set_base(base)
    local scripts = ScriptLoader.new(state)
    return setmetatable({guard=guard, package_state=state, script_loader=scripts}, TestBed)
end

return M
