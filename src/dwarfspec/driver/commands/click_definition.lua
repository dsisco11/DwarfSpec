-- Verified definition for generic exactly-once clicks.

local CommandKind = require('dwarfspec.protocol.enums.command_kinds')
local IntrinsicKind = require(
    'dwarfspec.protocol.enums.intrinsic_verification_kinds')
local Outcomes = require('dwarfspec.driver.command.outcomes')
local RetryPolicy = require(
    'dwarfspec.protocol.enums.execution_retry_policies')
local SubjectTokens = require('dwarfspec.driver.command.subject_tokens')

---@class dwarfspec.ClickCommandDefinition
---@field private _runtime dwarfspec.ClickRuntime
---@field private _subjects dwarfspec.CommandSubjectTokens
local ClickDefinition = {}
ClickDefinition.__index = ClickDefinition

---Creates the generic click definition owner.
---@param runtime dwarfspec.ClickRuntime
---@return dwarfspec.ClickCommandDefinition
function ClickDefinition.new(runtime)
    assert(type(runtime) == 'table', 'click command runtime is required')
    for _, name in ipairs({'resolve', 'dispatch', 'capture_render',
            'observe_render'}) do
        assert(type(runtime[name]) == 'function',
            'click command runtime requires ' .. name)
    end
    return setmetatable({_runtime=runtime,
        _subjects=SubjectTokens.new()}, ClickDefinition)
end

---Normalizes a click request and validates its button.
---@param arguments table
---@param subject_token table
---@return table
function ClickDefinition:_normalize(arguments, subject_token)
    local button = arguments.button or 'left'
    assert(({left=true, right=true, middle=true})[button],
        'unsupported mouse button: ' .. tostring(button))
    return {subject_token=subject_token, button=button}
end

---Re-resolves the mounted interaction target immediately before dispatch.
---@param subject table
---@return table
function ClickDefinition:_preflight(subject)
    return self._runtime:resolve(subject)
end

---Dispatches one exactly-once click and creates its intrinsic receipt.
---@param command_context table
---@param request table
---@param readiness table
---@return any, table
function ClickDefinition:_execute(command_context, request, readiness)
    local prior_generation = self._runtime:capture_render(command_context)
    local public_result = self._runtime:dispatch(
        readiness.subject, request.button)
    return public_result, {ingress='dfhack.simulateInput',
        pointer_positioned=true, transient_state_restored=true,
        render_generation=prior_generation}
end

---Verifies the reliable input and render-settling guarantees.
---@param command_context table
---@param receipt table
---@return table
function ClickDefinition:_verify(command_context, receipt)
    assert(receipt.ingress == 'dfhack.simulateInput' and
            receipt.pointer_positioned == true and
            receipt.transient_state_restored == true and
            type(receipt.render_generation) == 'number',
        'click receipt does not prove reliable input guarantees')
    if not self._runtime:observe_render(
            command_context, receipt.render_generation) then
        return Outcomes.pending('click render has not settled',
            {render_generation=receipt.render_generation})
    end
    return Outcomes.ready(true, receipt)
end

---Creates the immutable action definition.
---@return table
function ClickDefinition:definition()
    return {name='click', kind=CommandKind.ACTION,
        normalize=function(arguments)
            return self:_normalize(arguments,
                self._subjects:retain(arguments.subject))
        end,
        preflight=function(context, request)
            return Outcomes.ready(self:_preflight(
                self._subjects:resolve(request.subject_token)))
        end,
        execute=function(context, request, readiness)
            local public_result, receipt = self:_execute(
                context, request, readiness)
            return Outcomes.executed(public_result, receipt)
        end,
        verify=function(context, _, receipt)
            return self:_verify(context, receipt)
        end,
        execution_retry_policy=RetryPolicy.ONCE,
        intrinsic_verification=IntrinsicKind.CALLBACK}
end

---Registers and binds the public generic click command.
---@param ds table
---@param command_runner dwarfspec.CommandRunner
---@param runtime dwarfspec.ClickRuntime
---@return dwarfspec.CommandDefinition
function ClickDefinition.bind(ds, command_runner, runtime)
    assert(type(ds) == 'table', 'click command requires the public namespace')
    assert(type(command_runner) == 'table' and
            type(command_runner.registerBuiltin) == 'function' and
            type(command_runner.invoke) == 'function',
        'click command requires the verified command runner')
    local definition = command_runner:registerBuiltin(
        ClickDefinition.new(runtime):definition())

    ---Clicks one mounted subject through the verified action contract.
    ---@param subject table
    ---@param button? string
    ---@param command_options? table
    ---@return any
    function ds.click(subject, button, command_options)
        return command_runner:invoke('click',
            {subject=subject, button=button}, command_options)
    end
    return definition
end

return ClickDefinition
