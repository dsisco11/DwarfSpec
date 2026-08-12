-- Verified get command owner.

local MountQuery = require('dwarfspec.driver.builtins.mount_query_command')

---@class dwarfspec.GetCommand
local Get = {}
Get.__index = Get

---Creates the get command owner.
---@param runtime dwarfspec.MountQueryRuntime
---@return dwarfspec.GetCommand
function Get.new(runtime)
    return setmetatable({_command=MountQuery.new({name='get',
        runtime=runtime, request=function(arguments)
            return {control_path=arguments.control_path,
                options=arguments.options}
        end, execute=function(arguments)
            return runtime:get(arguments.control_path, arguments.options)
        end})}, Get)
end

---Returns the immutable get definition.
---@return dwarfspec.CommandDefinition
function Get:definition() return self._command:definition() end

---Adapts the public get signature.
---@param control_path any
---@param options? table
---@param command_options? table
---@return table, table|nil
function Get:arguments(control_path, options, command_options)
    return {control_path=control_path, options=options}, command_options
end

return Get
