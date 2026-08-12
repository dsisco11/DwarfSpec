-- Verified getGameSpeed command owner.

local ScalarQuery = require(
    'dwarfspec.driver.builtins.scalar_query_command')

---@class dwarfspec.GetGameSpeedCommand
local GetGameSpeed = {}
GetGameSpeed.__index = GetGameSpeed

---Creates the getGameSpeed command owner.
---@param runtime dwarfspec.GameQueryRuntime
---@return dwarfspec.GetGameSpeedCommand
function GetGameSpeed.new(runtime)
    return setmetatable({_command=ScalarQuery.new('getGameSpeed',
        function() return runtime:get_game_speed() end)}, GetGameSpeed)
end

---Returns the immutable getGameSpeed definition.
---@return dwarfspec.CommandDefinition
function GetGameSpeed:definition() return self._command:build_definition() end

---Adapts the public getGameSpeed signature.
---@param command_options? table
---@return table, table|nil
function GetGameSpeed:arguments(command_options)
    return {}, command_options
end

return GetGameSpeed
