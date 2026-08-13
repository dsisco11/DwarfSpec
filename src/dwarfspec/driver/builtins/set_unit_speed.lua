-- Verified setUnitSpeed command owner.

local Outcomes = require('dwarfspec.driver.command.outcomes')
local StateSetterCommand = require(
    'dwarfspec.driver.builtins.state_setter_command')

---@class dwarfspec.SetUnitSpeedCommand
---@field private _runtime dwarfspec.UnitSpeedRuntime
---@field private _definition table
local SetUnitSpeed = {}
SetUnitSpeed.__index = SetUnitSpeed

---Returns whether two captured ID arrays match.
---@param left table
---@param right table
---@return boolean
local function ids_match(left, right)
    if #left ~= #right then return false end
    for index, id in ipairs(left) do
        if right[index] ~= id then return false end
    end
    return true
end

---Returns whether ownership proves one exact configuration.
---@param state table
---@param configuration table
---@return boolean
local function state_matches(state, configuration)
    local current = state.configuration
    return state.active == true and state.recurring.unit_speed_active == true and
        current ~= nil and
        current.fast_actions == configuration.fast_actions and
        current.teleport_jobs == configuration.teleport_jobs and
        ids_match(current.unit_ids, configuration.unit_ids)
end

---Creates the setUnitSpeed command owner.
---@param runtime dwarfspec.UnitSpeedRuntime
---@return dwarfspec.SetUnitSpeedCommand
function SetUnitSpeed.new(runtime)
    assert(type(runtime) == 'table',
        'setUnitSpeed requires the unit-speed runtime')
    local builder = StateSetterCommand.new({name='setUnitSpeed',
        normalize=function(arguments)
            assert(type(arguments.options) == 'table',
                'setUnitSpeed options must be a table')
            return {options=arguments.options}
        end,
        preflight=function(request)
            return {configuration=runtime:prepare(request.options),
                target_identity='unit-speed'}
        end,
        execute=function(request, readiness)
            local ok, failure = pcall(runtime.activate, runtime,
                readiness.configuration)
            local state = runtime:state()
            local receipt = {configuration=readiness.configuration,
                target_identity=readiness.target_identity}
            if not ok then
                return Outcomes.failed(tostring(failure),
                    (state.active or state.recurring.unit_speed_active) and
                        receipt or nil,
                    state)
            end
            return Outcomes.executed(nil, receipt, receipt)
        end,
        verify=function(request, receipt)
            local state = runtime:state()
            if state_matches(state, receipt.configuration) then
                return Outcomes.ready(true, state)
            end
            return Outcomes.pending(
                'unit-speed ownership is not yet confirmed', state)
        end,
        restore=function() return runtime:restore() end,
        verify_restored=function()
            local state = runtime:state()
            return state.active == false and
                state.recurring.unit_speed_active == false
        end,
    })
    return setmetatable({_runtime=runtime,
        _definition=builder:build_definition()}, SetUnitSpeed)
end

---Returns the immutable command definition.
---@return table
function SetUnitSpeed:definition() return self._definition end

---Adapts the public signature.
---@param options table
---@param command_options? table
---@return table, table|nil
function SetUnitSpeed:arguments(options, command_options)
    return {options=options}, command_options
end

return SetUnitSpeed
