-- Verified getTime command owner.

local ScalarQuery = require(
    'dwarfspec.driver.builtins.scalar_query_command')

---@class dwarfspec.GetTimeCommand
local GetTime = {}
GetTime.__index = GetTime

---Creates the getTime command owner.
---@param runtime dwarfspec.GameQueryRuntime
---@return dwarfspec.GetTimeCommand
function GetTime.new(runtime)
    return setmetatable({_command=ScalarQuery.new('getTime',
        function() return runtime:get_time() end)}, GetTime)
end

---Returns the immutable getTime definition.
---@return dwarfspec.CommandDefinition
function GetTime:definition() return self._command:build_definition() end

---Adapts the public getTime signature.
---@param command_options? table
---@return table, table|nil
function GetTime:arguments(command_options)
    return {}, command_options
end

return GetTime
