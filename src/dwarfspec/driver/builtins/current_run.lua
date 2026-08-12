-- Verified current_run command owner.

local ReadOnlyCommand = require(
    'dwarfspec.driver.builtins.read_only_command')

---@class dwarfspec.CurrentRunCommand
local CurrentRun = {}
CurrentRun.__index = CurrentRun

---Creates the current_run command owner.
---@param runtime dwarfspec.RunQueryRuntime
---@return dwarfspec.CurrentRunCommand
function CurrentRun.new(runtime)
    return setmetatable({_command=ReadOnlyCommand.new({name='current_run',
        normalize=function() return {} end,
        execute=function() return runtime:current_run() end})}, CurrentRun)
end

---Returns the immutable current_run definition.
---@return dwarfspec.CommandDefinition
function CurrentRun:definition() return self._command:definition() end

---Adapts the public current_run signature.
---@param command_options? table
---@return table, table|nil
function CurrentRun:arguments(command_options)
    return {}, command_options
end

return CurrentRun
