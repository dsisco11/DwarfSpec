-- Verified capture_view_tree command owner.

local MountQuery = require('dwarfspec.driver.builtins.mount_query_command')

---@class dwarfspec.CaptureViewTreeCommand
local CaptureViewTree = {}
CaptureViewTree.__index = CaptureViewTree

---Creates the capture_view_tree command owner.
---@param runtime dwarfspec.MountQueryRuntime
---@return dwarfspec.CaptureViewTreeCommand
function CaptureViewTree.new(runtime)
    return setmetatable({_command=MountQuery.new({name='capture_view_tree',
        runtime=runtime, request=function(arguments)
            return {name=arguments.name, options=arguments.options}
        end, execute=function(arguments)
            return runtime:capture_view_tree(
                arguments.name, arguments.options)
        end})}, CaptureViewTree)
end

---Returns the immutable capture_view_tree definition.
---@return dwarfspec.CommandDefinition
function CaptureViewTree:definition() return self._command:definition() end

---Adapts the public capture_view_tree signature.
---@param name string
---@param options? table
---@param command_options? table
---@return table, table|nil
function CaptureViewTree:arguments(name, options, command_options)
    return {name=name, options=options}, command_options
end

return CaptureViewTree
