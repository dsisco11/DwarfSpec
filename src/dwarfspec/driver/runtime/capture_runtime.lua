-- Run-owned evidence capture capability.

---@class dwarfspec.CaptureRuntime
---@field private _run table
---@field private _diagnostics table
local CaptureRuntime = {}
CaptureRuntime.__index = CaptureRuntime

---Creates the evidence capture capability.
---@param options table
---@return dwarfspec.CaptureRuntime
function CaptureRuntime.new(options)
    assert(type(options) == 'table',
        'capture runtime options are required')
    assert(type(options.run) == 'table', 'capture runtime requires a run')
    assert(type(options.diagnostics) == 'table' and
            type(options.diagnostics.capture_screen) == 'function',
        'capture runtime requires diagnostics')
    return setmetatable({_run=options.run,
        _diagnostics=options.diagnostics}, CaptureRuntime)
end

---Captures and replaces one named screen artifact.
---@param name string
---@param options? table
---@return table
function CaptureRuntime:capture_screen(name, options)
    self._run.captures = self._run.captures or {}
    local capture = self._diagnostics.capture_screen(options)
    self._run.captures[name] = capture
    return capture
end

return CaptureRuntime
