-- Verified wait_ticks command owner.

local CommandKind = require('dwarfspec.protocol.enums.command_kinds')
local ReadOnlyDefinition = require(
    'dwarfspec.driver.command.read_only_definition')
local WaitSupport = require('dwarfspec.driver.builtins.wait_support')

---@class dwarfspec.WaitTicksCommand
local WaitTicks = {}
WaitTicks.__index = WaitTicks

---Creates the wait_ticks command owner.
---@param runtime dwarfspec.WaitRuntime
---@return dwarfspec.WaitTicksCommand
function WaitTicks.new(runtime)
    return setmetatable({_runtime=assert(runtime),
        _support=WaitSupport.new()}, WaitTicks)
end

---Creates the wait_ticks definition.
---@return dwarfspec.CommandDefinition
function WaitTicks:definition()
    return ReadOnlyDefinition.new({name='wait_ticks',
        kind=CommandKind.ASSERTION,
        normalize=function(arguments)
            return {count=self._support:count(arguments.count,
                'simulation tick'), options=self._support:options(
                    arguments.options, false, false)}
        end,
        observe=function(context, request)
            return self._support:observe(function()
                return self._runtime:wait_ticks(request.count,
                    request.options, context:remaining_ms())
            end)
        end}):definition()
end

---Adapts the public wait_ticks signature for the runner.
---@param count integer
---@param options? table
---@param command_options? table
---@return table, table|nil
function WaitTicks:arguments(count, options, command_options)
    return {count=count, options=options},
        self._support:command_options(options, command_options)
end

return WaitTicks
