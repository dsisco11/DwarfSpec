-- Verified getTick command owner.

local ScalarQuery = require(
    'dwarfspec.driver.builtins.scalar_query_command')

---@class dwarfspec.GetTickCommand
local GetTick = {}
GetTick.__index = GetTick

---Creates the getTick command owner.
---@param runtime dwarfspec.GameQueryRuntime
---@return dwarfspec.GetTickCommand
function GetTick.new(runtime)
    return setmetatable({_command=ScalarQuery.new('getTick',
        function() return runtime:get_tick() end)}, GetTick)
end

---Returns the immutable getTick definition.
---@return dwarfspec.CommandDefinition
function GetTick:definition() return self._command:build_definition() end

---Adapts the public getTick signature.
---@param command_options? table
---@return table, table|nil
function GetTick:arguments(command_options)
    return {}, command_options
end

return GetTick
