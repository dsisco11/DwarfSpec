-- Verified definition for reversible map-view positioning.

local CleanupLifetime = require(
    'dwarfspec.protocol.enums.cleanup_lifetimes')
local CommandKind = require('dwarfspec.protocol.enums.command_kinds')
local IntrinsicKind = require(
    'dwarfspec.protocol.enums.intrinsic_verification_kinds')
local Outcomes = require('dwarfspec.driver.command.outcomes')
local RetryPolicy = require(
    'dwarfspec.protocol.enums.execution_retry_policies')
local Definition = require('dwarfspec.driver.command.definition')

---@class dwarfspec.ViewPositionCommandDefinition
---@field private _runtime dwarfspec.MapViewRuntime
local ViewPositionDefinition = {}
ViewPositionDefinition.__index = ViewPositionDefinition

---Creates the reversible setViewPos command owner.
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

---Returns whether two raw top-left positions match.
---@param left table
---@param right table
---@return boolean
function ViewPositionDefinition:_positions_match(left, right)
    return left.x == right.x and left.y == right.y and left.z == right.z
end

---Applies the raw position and returns a truthful execution outcome.
---@param readiness table
---@return table
function ViewPositionDefinition:_execute(readiness)
    local ok, accepted = pcall(self._runtime.set_position, self._runtime,
        readiness.raw.x, readiness.raw.y, readiness.raw.z)
    local receipt = {baseline=readiness.baseline,
        requested=readiness.requested, raw=readiness.raw,
        target_identity=readiness.target_identity}
    local observed = self._runtime:get_position(
        self._runtime:top_left_origin())
    local changed = not self:_positions_match(observed, readiness.baseline)
    if not ok then
        return Outcomes.failed(
            'DwarfSpec could not set the map-view position: ' ..
                tostring(accepted), changed and receipt or nil,
            {position=observed})
    end
    if accepted == false then
        return Outcomes.failed(
            'DFHack rejected the requested map-view position',
            changed and receipt or nil, {position=observed})
    end
    return Outcomes.executed(readiness.requested, receipt,
        changed and receipt or nil)
end

---Observes whether the requested position is applied.
---@param request table
---@return table
function ViewPositionDefinition:_verify(request, receipt)
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
    return Definition.validate({name='setViewPos', kind=CommandKind.STATE_SETTER,
        normalize=function(arguments) return self:_normalize(arguments) end,
        preflight=function(context, request)
            return Outcomes.ready(self:_preflight(request))
        end,
        execute=function(context, request, readiness)
            return self:_execute(readiness)
        end,
        verify=function(_, request, receipt)
            return self:_verify(request, receipt)
        end,
        cleanup={lifetime=CleanupLifetime.OWNER,
            restore=function(_, receipt) return self:_restore(receipt) end,
            verify=function(_, receipt)
                return self:_verify_restored(receipt)
            end},
        execution_retry_policy=RetryPolicy.ONCE,
        intrinsic_verification=IntrinsicKind.CALLBACK})
end

---Adapts the public setViewPos signature for the runner.
---@param position table
---@param origin? any
---@param command_options? table
---@return table, table|nil
function ViewPositionDefinition:arguments(position, origin, command_options)
    return {position=position, origin=origin}, command_options
end

return ViewPositionDefinition
