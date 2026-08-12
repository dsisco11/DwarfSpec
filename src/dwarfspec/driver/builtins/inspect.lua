-- Verified inspect command owner.

local MountQuery = require('dwarfspec.driver.builtins.mount_query_command')

---@class dwarfspec.InspectCommand
local Inspect = {}
Inspect.__index = Inspect

---Creates the inspect command owner.
---@param runtime dwarfspec.MountQueryRuntime
---@return dwarfspec.InspectCommand
function Inspect.new(runtime)
    return setmetatable({_command=MountQuery.new({name='inspect',
        runtime=runtime, request=function(arguments)
            return {view=arguments.view}
        end, execute=function(arguments)
            return runtime:inspect(arguments.view)
        end})}, Inspect)
end

---Returns the immutable inspect definition.
---@return dwarfspec.CommandDefinition
function Inspect:definition() return self._command:definition() end

---Adapts the public inspect signature.
---@param view? table
---@param command_options? table
---@return table, table|nil
function Inspect:arguments(view, command_options)
    return {view=view}, command_options
end

return Inspect
