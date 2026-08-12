-- Verified definition for reversible map-view positioning.

local CleanupLifetime = require(
    'dwarfspec.protocol.enums.cleanup_lifetimes')
local CommandKind = require('dwarfspec.protocol.enums.command_kinds')
local IntrinsicKind = require(
    'dwarfspec.protocol.enums.intrinsic_verification_kinds')
local Outcomes = require('dwarfspec.driver.command.outcomes')
local RetryPolicy = require(
    'dwarfspec.protocol.enums.execution_retry_policies')
local ReadOnlyDefinition = require(
    'dwarfspec.driver.command.read_only_definition')

---@class dwarfspec.ViewPositionCommandDefinition
---@field private _runtime dwarfspec.MapViewRuntime
local ViewPositionDefinition = {}
ViewPositionDefinition.__index = ViewPositionDefinition

---Creates the reversible view-position definition owner.
---@param runtime dwarfspec.MapViewRuntime
---@return dwarfspec.ViewPositionCommandDefinition
function ViewPositionDefinition.new(runtime)
    assert(type(runtime) == 'table',
        'view-position command runtime is required')
    for _, name in ipairs({'get_position', 'set_position', 'origin_offset',
            'top_left_origin'}) do
        assert(type(runtime[name]) == 'function',
            'view-position command runtime requires ' .. name)
    end
    return setmetatable({_runtime=runtime}, ViewPositionDefinition)
end

---Validates and copies one requested map-view position.
---@param arguments table
---@return table
function ViewPositionDefinition:_normalize(arguments)
    local position = arguments.position
    assert(type(position) == 'table',
        'map-view position must be a table with x, y, and z coordinates')
    local copy = {}
    for _, axis in ipairs({'x', 'y', 'z'}) do
        local value = position[axis]
        assert(type(value) == 'number' and value % 1 == 0 and value >= 0,
            ('map-view %s coordinate must be a nonnegative integer'):format(axis))
        copy[axis] = value
    end
    return {position=copy, origin=arguments.origin}
end

---Captures the baseline and converts the request to raw coordinates.
---@param request table
---@return table
function ViewPositionDefinition:_preflight(request)
    local baseline = self._runtime:get_position(
        self._runtime:top_left_origin())
    local offset_x, offset_y = self._runtime:origin_offset(request.origin)
    return {baseline=baseline, requested=request.position,
        raw={x=request.position.x - offset_x,
            y=request.position.y - offset_y, z=request.position.z},
        target_identity='map-view'}
end

---Applies the raw position and returns a reversible receipt.
---@param readiness table
---@return table, table
function ViewPositionDefinition:_execute(readiness)
    local ok, accepted = pcall(self._runtime.set_position, self._runtime,
        readiness.raw.x, readiness.raw.y, readiness.raw.z)
    assert(ok, 'DwarfSpec could not set the map-view position: ' ..
        tostring(accepted))
    assert(accepted ~= false, 'DFHack rejected the requested map-view position')
    return readiness.requested, {baseline=readiness.baseline,
        requested=readiness.requested, raw=readiness.raw}
end

---Observes whether the requested position is applied.
---@param request table
---@return table
function ViewPositionDefinition:_verify(request)
    local observed = self._runtime:get_position(request.origin)
    local expected = request.position
    if observed.x == expected.x and observed.y == expected.y and
            observed.z == expected.z then
        return Outcomes.ready(true, {position=observed})
    end
    return Outcomes.pending('map-view position is not yet applied',
        {position=observed})
end

---Restores the captured baseline.
---@param receipt table
function ViewPositionDefinition:_restore(receipt)
    local baseline = receipt.baseline
    assert(self._runtime:set_position(
        baseline.x, baseline.y, baseline.z) ~= false,
        'DFHack rejected the original map-view position')
end

---Verifies exact restoration of the captured baseline.
---@param receipt table
---@return boolean
function ViewPositionDefinition:_verify_restored(receipt)
    local observed = self._runtime:get_position(
        self._runtime:top_left_origin())
    local baseline = receipt.baseline
    return observed.x == baseline.x and observed.y == baseline.y and
        observed.z == baseline.z
end

---Creates the immutable state-setter definition.
---@return table
function ViewPositionDefinition:definition()
    return {name='setViewPos', kind=CommandKind.STATE_SETTER,
        normalize=function(arguments) return self:_normalize(arguments) end,
        preflight=function(context, request)
            return Outcomes.ready(self:_preflight(request))
        end,
        execute=function(context, request, readiness)
            local result, receipt = self:_execute(readiness)
            return Outcomes.executed(result, receipt, receipt)
        end,
        verify=function(_, request) return self:_verify(request) end,
        cleanup={lifetime=CleanupLifetime.OWNER,
            restore=function(_, receipt) return self:_restore(receipt) end,
            verify=function(_, receipt)
                return self:_verify_restored(receipt)
            end},
        execution_retry_policy=RetryPolicy.ONCE,
        intrinsic_verification=IntrinsicKind.CALLBACK}
end

---Creates the immutable map-view position query definition.
---@return table
function ViewPositionDefinition:queryDefinition()
    return ReadOnlyDefinition.new({name='getViewPos',
        kind=CommandKind.QUERY,
        normalize=function(arguments) return {origin=arguments.origin} end,
        execute=function(_, request)
            return self._runtime:get_position(request.origin)
        end}):definition()
end

---Registers and binds the public map-view position command.
---@param ds table
---@param command_runner dwarfspec.CommandRunner
---@param runtime dwarfspec.MapViewRuntime
---@return dwarfspec.CommandDefinition
function ViewPositionDefinition.bind(ds, command_runner, runtime)
    assert(type(ds) == 'table',
        'view-position command requires the public namespace')
    assert(type(command_runner) == 'table' and
            type(command_runner.registerBuiltin) == 'function' and
            type(command_runner.invoke) == 'function',
        'view-position command requires the verified command runner')
    local owner = ViewPositionDefinition.new(runtime)
    command_runner:registerBuiltin(owner:queryDefinition())
    local definition = command_runner:registerBuiltin(owner:definition())

    ---Returns the map tile aligned with one screen origin.
    ---@param origin? any
    ---@param command_options? table
    ---@return table
    function ds.getViewPos(origin, command_options)
        return command_runner:invoke('getViewPos', {origin=origin},
            command_options)
    end

    ---Sets the map-view position through the verified state-setter contract.
    ---@param position table
    ---@param origin? any
    ---@param command_options? table
    ---@return table
    function ds.setViewPos(position, origin, command_options)
        return command_runner:invoke('setViewPos',
            {position=position, origin=origin}, command_options)
    end
    return definition
end

return ViewPositionDefinition
