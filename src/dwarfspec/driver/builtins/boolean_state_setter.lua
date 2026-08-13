-- Shared boolean state-setter mechanics below command-owner interfaces.

local Outcomes = require('dwarfspec.driver.command.outcomes')
local StateSetterCommand = require(
    'dwarfspec.driver.builtins.state_setter_command')

---@class dwarfspec.BooleanStateSetterBuilder
---@field private _definition table
local BooleanStateSetter = {}
BooleanStateSetter.__index = BooleanStateSetter

---Creates shared mechanics for one named boolean setter.
---@param options table
---@return dwarfspec.BooleanStateSetterBuilder
function BooleanStateSetter.new(options)
    assert(type(options) == 'table',
        'boolean state-setter options are required')
    assert(type(options.name) == 'string' and options.name ~= '',
        'boolean state-setter requires a name')
    assert(type(options.runtime) == 'table',
        'boolean state-setter requires a runtime')
    assert(type(options.read) == 'string' and
            type(options.runtime[options.read]) == 'function',
        'boolean state-setter requires a read method')
    assert(type(options.write) == 'string' and
            type(options.runtime[options.write]) == 'function',
        'boolean state-setter requires a write method')
    local runtime = options.runtime
    local read = options.read
    local write = options.write
    local label = options.label or options.name
    local builder = StateSetterCommand.new({
        name=options.name,
        normalize=function(arguments)
            assert(type(arguments.value) == 'boolean',
                label .. ' state must be a boolean')
            return {value=arguments.value}
        end,
        preflight=function(request)
            return {baseline=runtime[read](runtime), requested=request.value,
                target_identity=options.name}
        end,
        execute=function(request, readiness)
            local ok, accepted = pcall(runtime[write], runtime,
                readiness.requested)
            local observed = runtime[read](runtime)
            local receipt = {baseline=readiness.baseline,
                requested=readiness.requested, observed=observed,
                target_identity=readiness.target_identity}
            local changed = observed ~= readiness.baseline
            if not ok then
                return Outcomes.failed(tostring(accepted),
                    changed and receipt or nil, {observed=observed})
            end
            if accepted == false then
                return Outcomes.failed('DFHack rejected the requested ' ..
                    label .. ' state', changed and receipt or nil,
                    {observed=observed})
            end
            return Outcomes.executed(request.value, receipt,
                changed and receipt or nil)
        end,
        verify=function(request, receipt)
            local observed = runtime[read](runtime)
            if observed == request.value then
                return Outcomes.ready(true, {observed=observed})
            end
            return Outcomes.pending(label .. ' state is not yet applied',
                {observed=observed})
        end,
        restore=function(receipt)
            assert(runtime[write](runtime, receipt.baseline) ~= false,
                'DFHack rejected the original ' .. label .. ' state')
        end,
        verify_restored=function(receipt)
            return runtime[read](runtime) == receipt.baseline
        end,
    })
    return setmetatable({_definition=builder:build_definition()},
        BooleanStateSetter)
end

---Returns the immutable built definition.
---@return table
function BooleanStateSetter:build_definition()
    return self._definition
end

return BooleanStateSetter
