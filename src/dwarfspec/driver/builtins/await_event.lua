-- Verified awaitEvent command owner.

local CommandKind = require('dwarfspec.protocol.enums.command_kinds')
local OpaqueTokens = require('dwarfspec.driver.command.opaque_tokens')
local ReadOnlyDefinition = require(
    'dwarfspec.driver.command.read_only_definition')
local WaitSupport = require('dwarfspec.driver.builtins.wait_support')

---@class dwarfspec.AwaitEventCommand
local AwaitEvent = {}
AwaitEvent.__index = AwaitEvent

---Creates the awaitEvent command owner.
---@param runtime dwarfspec.WaitRuntime
---@return dwarfspec.AwaitEventCommand
function AwaitEvent.new(runtime)
    return setmetatable({_runtime=assert(runtime),
        _support=WaitSupport.new(), _opaque=OpaqueTokens.new()}, AwaitEvent)
end

---Creates the awaitEvent definition.
---@return dwarfspec.CommandDefinition
function AwaitEvent:definition()
    return ReadOnlyDefinition.new({name='awaitEvent',
        kind=CommandKind.ASSERTION,
        normalize=function(arguments)
            assert(arguments.event ~= nil, 'awaitEvent requires an event')
            local options = self._support:options(
                arguments.options, false, true)
            if options.trigger then
                options.trigger_token = self._opaque:retain(options.trigger)
                options.trigger = nil
            end
            return {event=arguments.event, options=options}
        end,
        observe=function(context, request)
            return self._support:observe(function()
                local options = {}
                for name, value in pairs(request.options) do
                    if name ~= 'trigger_token' then options[name] = value end
                end
                if request.options.trigger_token then
                    options.trigger = self._opaque:resolve(
                        request.options.trigger_token)
                end
                return self._runtime:wait_event(request.event, options,
                    context:remaining_ms())
            end)
        end}):definition()
end

---Adapts the public awaitEvent signature for the runner.
---@param event any
---@param options? table
---@param command_options? table
---@return table, table|nil
function AwaitEvent:arguments(event, options, command_options)
    return {event=event, options=options},
        self._support:command_options(options, command_options)
end

return AwaitEvent
