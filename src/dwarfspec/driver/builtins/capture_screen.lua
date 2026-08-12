-- Verified capture_screen command owner.

local OpaqueTokens = require('dwarfspec.driver.command.opaque_tokens')
local ReadOnlyCommand = require(
    'dwarfspec.driver.builtins.read_only_command')

---@class dwarfspec.CaptureScreenCommand
local CaptureScreen = {}
CaptureScreen.__index = CaptureScreen

---Creates the capture_screen command owner.
---@param runtime dwarfspec.CaptureRuntime
---@return dwarfspec.CaptureScreenCommand
function CaptureScreen.new(runtime)
    local opaque = OpaqueTokens.new()
    return setmetatable({_command=ReadOnlyCommand.new({
        name='capture_screen',
        normalize=function(arguments)
            return {arguments_token=opaque:retain({name=arguments.name,
                options=arguments.options})}
        end,
        execute=function(_, request)
            local arguments = opaque:resolve(request.arguments_token)
            return runtime:capture_screen(arguments.name, arguments.options)
        end})}, CaptureScreen)
end

---Returns the immutable capture_screen definition.
---@return dwarfspec.CommandDefinition
function CaptureScreen:definition() return self._command:definition() end

---Adapts the public capture_screen signature.
---@param name string
---@param options? table
---@param command_options? table
---@return table, table|nil
function CaptureScreen:arguments(name, options, command_options)
    return {name=name, options=options}, command_options
end

return CaptureScreen
