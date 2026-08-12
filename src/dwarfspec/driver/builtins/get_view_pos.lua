-- Verified getViewPos command owner.

local ReadOnlyCommand = require(
    'dwarfspec.driver.builtins.read_only_command')

---@class dwarfspec.GetViewPosCommand
local GetViewPos = {}
GetViewPos.__index = GetViewPos

---Creates the getViewPos command owner.
---@param runtime dwarfspec.MapViewRuntime
---@return dwarfspec.GetViewPosCommand
function GetViewPos.new(runtime)
    return setmetatable({_command=ReadOnlyCommand.new({name='getViewPos',
        normalize=function(arguments) return {origin=arguments.origin} end,
        execute=function(_, request)
            return runtime:get_position(request.origin)
        end})}, GetViewPos)
end

---Returns the immutable getViewPos definition.
---@return dwarfspec.CommandDefinition
function GetViewPos:definition() return self._command:definition() end

---Adapts the public getViewPos signature.
---@param origin? any
---@param command_options? table
---@return table, table|nil
function GetViewPos:arguments(origin, command_options)
    return {origin=origin}, command_options
end

return GetViewPos
