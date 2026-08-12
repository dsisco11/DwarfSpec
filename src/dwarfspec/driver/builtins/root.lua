-- Verified root command owner.

local MountQuery = require('dwarfspec.driver.builtins.mount_query_command')

---@class dwarfspec.RootCommand
local Root = {}
Root.__index = Root

---Creates the root command owner.
---@param runtime dwarfspec.MountQueryRuntime
---@return dwarfspec.RootCommand
function Root.new(runtime)
    return setmetatable({_command=MountQuery.new({name='root',
        runtime=runtime, request=function(arguments)
            return {options=arguments.options}
        end, execute=function(arguments)
            return runtime:root(arguments.options)
        end})}, Root)
end

---Returns the immutable root definition.
---@return dwarfspec.CommandDefinition
function Root:definition() return self._command:definition() end

---Adapts the public root signature.
---@param options? table
---@param command_options? table
---@return table, table|nil
function Root:arguments(options, command_options)
    return {options=options}, command_options
end

return Root
