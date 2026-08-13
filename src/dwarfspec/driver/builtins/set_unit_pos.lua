-- Verified setUnitPos command owner.

local Outcomes = require('dwarfspec.driver.command.outcomes')
local StateSetterCommand = require(
    'dwarfspec.driver.builtins.state_setter_command')

---@class dwarfspec.SetUnitPosCommand
---@field private _runtime dwarfspec.UnitPositionRuntime
---@field private _definition table
local SetUnitPos = {}
SetUnitPos.__index = SetUnitPos

---Returns whether two coordinates match.
---@param left table
---@param right table
---@return boolean
local function positions_match(left, right)
    return left and right and left.x == right.x and left.y == right.y and
        left.z == right.z
end

---Returns whether an observation proves the requested arrival.
---@param observation table|nil
---@param receipt table
---@return boolean
local function arrival_matches(observation, receipt)
    if observation == nil or observation.unit == nil or
            not positions_match(observation.unit.position,
                receipt.destination) then
        return false
    end
    local baseline_occupancy = receipt.baseline.occupancy
    local arrival_occupancy = receipt.arrival.occupancy
    if receipt.baseline.on_ground then
        return observation.source.unit_grounded == false and
            observation.source.unit == baseline_occupancy.unit and
            observation.destination.unit_grounded == true and
            observation.destination.unit == arrival_occupancy.unit
    end
    return observation.source.unit == false and
        observation.source.unit_grounded == baseline_occupancy.unit_grounded and
        observation.destination.unit == true and
        observation.destination.unit_grounded ==
            arrival_occupancy.unit_grounded
end

---Returns whether an observation proves the original baseline.
---@param observation table|nil
---@param baseline table
---@return boolean
local function baseline_matches(observation, baseline)
    return observation ~= nil and
        positions_match(observation.position, baseline.position) and
        positions_match(observation.idle_area, baseline.idle_area) and
        observation.on_ground == baseline.on_ground and
        observation.occupancy.unit == baseline.occupancy.unit and
        observation.occupancy.unit_grounded ==
            baseline.occupancy.unit_grounded
end

---Builds a cleanup receipt when execution changed the observed unit state.
---@param readiness table
---@param observation table|nil
---@return table|nil
local function partial_receipt(readiness, observation)
    if observation == nil or
            baseline_matches(observation, readiness.baseline) then
        return nil
    end
    return {unit_id=readiness.unit_id,
        baseline=readiness.baseline,
        destination=readiness.destination,
        arrival={position=observation.position,
            occupancy=observation.occupancy}}
end

---Creates the setUnitPos command owner.
---@param runtime dwarfspec.UnitPositionRuntime
---@return dwarfspec.SetUnitPosCommand
function SetUnitPos.new(runtime)
    assert(type(runtime) == 'table',
        'setUnitPos requires the unit-position runtime')
    local builder = StateSetterCommand.new({name='setUnitPos',
        normalize=function(arguments)
            assert(type(arguments.unit_id) == 'number' and
                    arguments.unit_id % 1 == 0,
                'unit id must be an integer')
            assert(type(arguments.position) == 'table',
                'unit position must be a table')
            return {unit_id=arguments.unit_id,
                position={x=arguments.position.x, y=arguments.position.y,
                    z=arguments.position.z}}
        end,
        preflight=function(request)
            return runtime:prepare(request.unit_id, request.position)
        end,
        execute=function(request, readiness)
            local ok, moved, receipt = pcall(runtime.apply, runtime,
                readiness)
            if not ok then
                local observed = runtime:observe(request.unit_id)
                return Outcomes.failed(tostring(moved),
                    partial_receipt(readiness, observed), observed)
            end
            if not moved or receipt == nil then
                local observed = runtime:observe(request.unit_id)
                return Outcomes.failed(
                    'DwarfSpec could not safely set the unit position',
                    partial_receipt(readiness, observed), observed)
            end
            return Outcomes.executed(nil, receipt, receipt)
        end,
        verify=function(request, receipt)
            local observed = runtime:observe_transition(
                request.unit_id, receipt)
            if arrival_matches(observed, receipt) then
                return Outcomes.ready(true, observed)
            end
            return Outcomes.pending('unit position is not yet applied',
                observed or {unit_id=request.unit_id, unavailable=true})
        end,
        restore=function(receipt) return runtime:restore(receipt) end,
        verify_restored=function(receipt)
            return baseline_matches(runtime:observe(receipt.unit_id),
                receipt.baseline)
        end,
    })
    return setmetatable({_runtime=runtime,
        _definition=builder:build_definition()}, SetUnitPos)
end

---Returns the immutable command definition.
---@return table
function SetUnitPos:definition() return self._definition end

---Adapts the public signature.
---@param unit_id integer
---@param position table
---@param command_options? table
---@return table, table|nil
function SetUnitPos:arguments(unit_id, position, command_options)
    return {unit_id=unit_id, position=position}, command_options
end

return SetUnitPos
