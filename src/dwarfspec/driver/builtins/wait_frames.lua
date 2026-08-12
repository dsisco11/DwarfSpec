-- Verified wait_frames command owner.

local CommandKind = require('dwarfspec.protocol.enums.command_kinds')
local ReadOnlyDefinition = require(
    'dwarfspec.driver.command.read_only_definition')
local WaitSupport = require('dwarfspec.driver.builtins.wait_support')

---@class dwarfspec.WaitFramesCommand
---@field private _runtime dwarfspec.WaitRuntime
---@field private _support dwarfspec.WaitCommandSupport
local WaitFrames = {}
WaitFrames.__index = WaitFrames

---Creates the wait_frames command owner.
---@param runtime dwarfspec.WaitRuntime
---@return dwarfspec.WaitFramesCommand
function WaitFrames.new(runtime)
    return setmetatable({_runtime=assert(runtime),
        _support=WaitSupport.new()}, WaitFrames)
end

---Creates the wait_frames definition.
---@return dwarfspec.CommandDefinition
function WaitFrames:definition()
    return ReadOnlyDefinition.new({name='wait_frames',
        kind=CommandKind.ASSERTION,
        normalize=function(arguments)
            return {count=self._support:count(arguments.count, 'frame'),
                options=self._support:options(arguments.options, false, false)}
        end,
        observe=function(context, request)
            return self._support:observe(function()
                return self._runtime:wait_frames(request.count,
                    request.options, context:remaining_ms())
            end)
        end}):definition()
end

---Adapts the public wait_frames signature for the runner.
---@param count integer
---@param options? table
---@param command_options? table
---@return table, table|nil
function WaitFrames:arguments(count, options, command_options)
    return {count=count, options=options},
        self._support:command_options(options, command_options)
end

return WaitFrames
