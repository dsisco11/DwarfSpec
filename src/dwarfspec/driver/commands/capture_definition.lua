-- Verified definition for bounded screen capture.

local CommandKind = require('dwarfspec.protocol.enums.command_kinds')
local OpaqueTokens = require('dwarfspec.driver.command.opaque_tokens')
local ReadOnlyDefinition = require(
    'dwarfspec.driver.command.read_only_definition')

---@class dwarfspec.ScreenCaptureCommandDefinition
---@field private _capture function
---@field private _opaque dwarfspec.CommandOpaqueTokens
local CaptureDefinition = {}
CaptureDefinition.__index = CaptureDefinition

---Creates the screen-capture definition owner.
---@param capture function
---@return dwarfspec.ScreenCaptureCommandDefinition
function CaptureDefinition.new(capture)
    assert(type(capture) == 'function', 'screen capture operation is required')
    return setmetatable({_capture=capture, _opaque=OpaqueTokens.new()},
        CaptureDefinition)
end

---Creates the immutable screen-capture query definition.
---@return table
function CaptureDefinition:definition()
    return ReadOnlyDefinition.new({name='capture_screen',
        kind=CommandKind.QUERY,
        normalize=function(arguments)
            return {arguments_token=self._opaque:retain({name=arguments.name,
                options=arguments.options})}
        end,
        execute=function(_, request)
            local arguments = self._opaque:resolve(request.arguments_token)
            return self._capture(arguments.name, arguments.options)
        end}):definition()
end

---Registers and binds bounded screen capture.
---@param ds table
---@param command_runner dwarfspec.CommandRunner
---@param capture function
function CaptureDefinition.bind(ds, command_runner, capture)
    command_runner:registerBuiltin(
        CaptureDefinition.new(capture):definition())

    ---Captures a bounded plain screen-cell buffer.
    ---@param name string
    ---@param options? table
    ---@param command_options? table
    ---@return table
    function ds.capture_screen(name, options, command_options)
        return command_runner:invoke('capture_screen',
            {name=name, options=options}, command_options)
    end
end

return CaptureDefinition
