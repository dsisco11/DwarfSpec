-- Verified isGamePaused command owner.

local ScalarQuery = require(
    'dwarfspec.driver.builtins.scalar_query_command')

---@class dwarfspec.IsGamePausedCommand
local IsGamePaused = {}
IsGamePaused.__index = IsGamePaused

---Creates the isGamePaused command owner.
---@param runtime dwarfspec.GameQueryRuntime
---@return dwarfspec.IsGamePausedCommand
function IsGamePaused.new(runtime)
    return setmetatable({_command=ScalarQuery.new('isGamePaused',
        function() return runtime:is_game_paused() end)}, IsGamePaused)
end

---Returns the immutable isGamePaused definition.
---@return dwarfspec.CommandDefinition
function IsGamePaused:definition() return self._command:build_definition() end

---Adapts the public isGamePaused signature.
---@param command_options? table
---@return table, table|nil
function IsGamePaused:arguments(command_options)
    return {}, command_options
end

return IsGamePaused
