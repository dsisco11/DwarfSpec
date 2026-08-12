-- Verified getSaveDirectoryName command owner.

local ScalarQuery = require(
    'dwarfspec.driver.builtins.scalar_query_command')

---@class dwarfspec.GetSaveDirectoryNameCommand
local GetSaveDirectoryName = {}
GetSaveDirectoryName.__index = GetSaveDirectoryName

---Creates the getSaveDirectoryName command owner.
---@param runtime dwarfspec.GameQueryRuntime
---@return dwarfspec.GetSaveDirectoryNameCommand
function GetSaveDirectoryName.new(runtime)
    return setmetatable({_command=ScalarQuery.new('getSaveDirectoryName',
        function() return runtime:get_save_directory_name() end)},
        GetSaveDirectoryName)
end

---Returns the immutable getSaveDirectoryName definition.
---@return dwarfspec.CommandDefinition
function GetSaveDirectoryName:definition()
    return self._command:build_definition()
end

---Adapts the public getSaveDirectoryName signature.
---@param command_options? table
---@return table, table|nil
function GetSaveDirectoryName:arguments(command_options)
    return {}, command_options
end

return GetSaveDirectoryName
