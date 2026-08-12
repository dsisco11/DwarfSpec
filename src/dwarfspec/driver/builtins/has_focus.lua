-- Verified hasFocus command owner.

local ReadOnlyCommand = require(
    'dwarfspec.driver.builtins.read_only_command')

---@class dwarfspec.HasFocusCommand
local HasFocus = {}
HasFocus.__index = HasFocus

---Creates the hasFocus command owner.
---@param runtime dwarfspec.GameQueryRuntime
---@return dwarfspec.HasFocusCommand
function HasFocus.new(runtime)
    return setmetatable({_command=ReadOnlyCommand.new({name='hasFocus',
        normalize=function(arguments)
            assert(type(arguments.path) == 'string' and arguments.path ~= '',
                'focus path must be a nonempty string')
            return {path=arguments.path}
        end,
        execute=function(_, request)
            return runtime:has_focus(request.path)
        end})}, HasFocus)
end

---Returns the immutable hasFocus definition.
---@return dwarfspec.CommandDefinition
function HasFocus:definition() return self._command:definition() end

---Adapts the public hasFocus signature.
---@param path string
---@param command_options? table
---@return table, table|nil
function HasFocus:arguments(path, command_options)
    return {path=path}, command_options
end

return HasFocus
