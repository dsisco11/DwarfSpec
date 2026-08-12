-- Run-scoped access to the service-owned active run.

---@class dwarfspec.RunQueryRuntime
---@field private _registry table
local RunQueryRuntime = {}
RunQueryRuntime.__index = RunQueryRuntime

---Creates the current-run query capability.
---@param registry table
---@return dwarfspec.RunQueryRuntime
function RunQueryRuntime.new(registry)
    assert(type(registry) == 'table',
        'run-query runtime requires the service registry')
    return setmetatable({_registry=registry}, RunQueryRuntime)
end

---Returns the exact service-owned active run.
---@return table
function RunQueryRuntime:current_run()
    local run_id = assert(self._registry.active_run_id,
        'DwarfSpec automation executor is idle')
    return assert(self._registry.runs[run_id],
        'DwarfSpec active run record is missing')
end

return RunQueryRuntime
