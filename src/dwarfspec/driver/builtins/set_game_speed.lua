-- Verified setGameSpeed command owner.

local Outcomes = require('dwarfspec.driver.command.outcomes')
local StateSetterCommand = require(
    'dwarfspec.driver.builtins.state_setter_command')

---@class dwarfspec.SetGameSpeedCommand
---@field private _runtime dwarfspec.GameStateRuntime
---@field private _definition table
local SetGameSpeed = {}
SetGameSpeed.__index = SetGameSpeed

---Returns whether two speed ratios are equivalent.
---@param left number
---@param right number
---@return boolean
local function ratio_matches(left, right)
    return math.abs(left - right) <= 1e-6 *
        math.max(1, math.abs(right))
end

---Returns whether two speed observations match exactly enough for DF rates.
---@param left table
---@param right table
---@return boolean
local function states_match(left, right)
    return left.tps == right.tps and
        ratio_matches(left.ratio, right.ratio)
end

---Returns whether readback proves the owned state without changing GFPS.
---@param observed table
---@param requested table
---@return boolean
local function applied_state_matches(observed, requested)
    return states_match(observed, requested) and
        observed.graphical_rate == requested.graphical_rate
end

---Creates the setGameSpeed command owner.
---@param runtime dwarfspec.GameStateRuntime
---@return dwarfspec.SetGameSpeedCommand
function SetGameSpeed.new(runtime)
    assert(type(runtime) == 'table' and
            type(runtime.speed_state) == 'function' and
            type(runtime.set_speed) == 'function',
        'setGameSpeed requires the game-state runtime')
    local builder = StateSetterCommand.new({name='setGameSpeed',
        normalize=function(arguments)
            local tps = arguments.tps
            assert(type(tps) == 'number' and tps == tps and
                    tps < math.huge and tps >= 1 and tps % 1 == 0,
                'game speed must be a positive integer TPS target')
            return {tps=tps}
        end,
        preflight=function(request)
            local baseline = runtime:speed_state()
            return {baseline=baseline,
                requested={tps=request.tps,
                    graphical_rate=baseline.graphical_rate,
                    ratio=request.tps / baseline.graphical_rate},
                target_identity='game-speed'}
        end,
        execute=function(request, readiness)
            local ok, accepted = pcall(runtime.set_speed, runtime,
                readiness.requested)
            local observed = runtime:speed_state()
            local receipt = {baseline=readiness.baseline,
                requested=readiness.requested, observed=observed,
                target_identity=readiness.target_identity}
            local changed = not states_match(observed, readiness.baseline)
            if not ok then
                return Outcomes.failed(tostring(accepted),
                    changed and receipt or nil, observed)
            end
            if accepted == false then
                return Outcomes.failed('DFHack rejected the requested game speed',
                    changed and receipt or nil, observed)
            end
            return Outcomes.executed(request.tps, receipt,
                changed and receipt or nil)
        end,
        verify=function(request, receipt)
            local observed = runtime:speed_state()
            if applied_state_matches(observed, receipt.requested) then
                return Outcomes.ready(true, observed)
            end
            return Outcomes.pending('game speed is not yet applied', observed)
        end,
        restore=function(receipt)
            assert(runtime:set_speed(receipt.baseline) ~= false,
                'DFHack rejected the original game speed')
        end,
        verify_restored=function(receipt)
            return states_match(runtime:speed_state(), receipt.baseline)
        end,
    })
    return setmetatable({_runtime=runtime,
        _definition=builder:build_definition()}, SetGameSpeed)
end

---Returns the immutable command definition.
---@return table
function SetGameSpeed:definition() return self._definition end

---Adapts the public signature.
---@param tps integer
---@param command_options? table
---@return table, table|nil
function SetGameSpeed:arguments(tps, command_options)
    return {tps=tps}, command_options
end

return SetGameSpeed
