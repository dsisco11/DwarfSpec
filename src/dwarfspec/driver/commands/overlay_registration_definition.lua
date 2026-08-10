-- Verified fixture definition for managed overlay registration.

local CleanupLifetime = require(
    'dwarfspec.protocol.enums.cleanup_lifetimes')
local CommandKind = require('dwarfspec.protocol.enums.command_kinds')
local IntrinsicKind = require(
    'dwarfspec.protocol.enums.intrinsic_verification_kinds')
local Outcomes = require('dwarfspec.driver.command.outcomes')
local RetryPolicy = require(
    'dwarfspec.protocol.enums.execution_retry_policies')

---@class dwarfspec.OverlayRegistrationCommandDefinition
---@field private _transaction dwarfspec.OverlayRegistrationTransaction
local OverlayRegistrationDefinition = {}
OverlayRegistrationDefinition.__index = OverlayRegistrationDefinition

---Creates the managed overlay-registration definition owner.
---@param transaction dwarfspec.OverlayRegistrationTransaction
---@return dwarfspec.OverlayRegistrationCommandDefinition
function OverlayRegistrationDefinition.new(transaction)
    assert(type(transaction) == 'table',
        'overlay-registration command requires transaction')
    for _, name in ipairs({'prepare', 'stage', 'bindings', 'verify',
            'restore', 'verify_absent'}) do
        assert(type(transaction[name]) == 'function',
            'overlay-registration transaction requires ' .. name)
    end
    return setmetatable({_transaction=transaction},
        OverlayRegistrationDefinition)
end

---Normalizes one overlay registration request.
---@param arguments table
---@return table
function OverlayRegistrationDefinition:_normalize(arguments)
    return {source_path=arguments.source_path,
        logical_name=arguments.logical_name}
end

---Prepares an inert overlay registration plan.
---@param request table
---@return table
function OverlayRegistrationDefinition:_plan(request)
    return self._transaction:prepare(
        request.source_path, request.logical_name)
end

---Stages the planned registration and returns its effect receipt.
---@param plan table
---@return table, table
function OverlayRegistrationDefinition:_stage(plan)
    local staged = self._transaction:stage(plan)
    return staged, staged
end

---Returns claim bindings created by the staged registration.
---@param receipt table
---@return table
function OverlayRegistrationDefinition:_bind_claims(receipt)
    return self._transaction:bindings(receipt)
end

---Verifies that the staged registration is observable.
---@param receipt table
---@return table
function OverlayRegistrationDefinition:_verify(receipt)
    if self._transaction:verify(receipt) then
        return Outcomes.ready(true, {path=receipt.path,
            registration_count=#receipt.registered_names})
    end
    return Outcomes.pending('overlay registration is not yet observable',
        {path=receipt.path})
end

---Restores the overlay registry from the effect receipt.
---@param receipt table
function OverlayRegistrationDefinition:_restore(receipt)
    self._transaction:restore(receipt)
end

---Verifies that the staged overlay registration is absent.
---@param receipt table
---@return boolean
function OverlayRegistrationDefinition:_verify_absent(receipt)
    return self._transaction:verify_absent(receipt)
end

---Creates the immutable fixture definition.
---@return table
function OverlayRegistrationDefinition:definition()
    return {name='stage_overlay_registration', kind=CommandKind.FIXTURE,
        normalize=function(arguments) return self:_normalize(arguments) end,
        preflight=function(context, request)
            return Outcomes.ready(self:_plan(request))
        end,
        claims=function(_, _, plan) return plan.claims end,
        execute=function(context, request, plan)
            local result, receipt = self:_stage(plan)
            return Outcomes.executed(result, receipt, receipt)
        end,
        verify=function(_, _, receipt) return self:_verify(receipt) end,
        cleanup={lifetime=CleanupLifetime.OWNER,
            resources=function(receipt) return self:_bind_claims(receipt) end,
            restore=function(_, receipt) return self:_restore(receipt) end,
            verify=function(_, receipt)
                return self:_verify_absent(receipt)
            end},
        execution_retry_policy=RetryPolicy.ONCE,
        intrinsic_verification=IntrinsicKind.CALLBACK}
end

---Registers and binds the public managed overlay fixture command.
---@param ds table
---@param command_runner dwarfspec.CommandRunner
---@param transaction dwarfspec.OverlayRegistrationTransaction
---@return dwarfspec.CommandDefinition
function OverlayRegistrationDefinition.bind(ds, command_runner, transaction)
    assert(type(ds) == 'table',
        'overlay-registration command requires the public namespace')
    assert(type(command_runner) == 'table' and
            type(command_runner.registerBuiltin) == 'function' and
            type(command_runner.invoke) == 'function',
        'overlay-registration command requires the verified command runner')
    local definition = command_runner:registerBuiltin(
        OverlayRegistrationDefinition.new(transaction):definition())

    ---Stages an overlay through the verified fixture contract.
    ---@param source_path string
    ---@param logical_name string
    ---@param command_options? table
    ---@return table
    function ds.stage_overlay_registration(source_path, logical_name,
            command_options)
        return command_runner:invoke('stage_overlay_registration',
            {source_path=source_path, logical_name=logical_name},
            command_options)
    end
    return definition
end

return OverlayRegistrationDefinition
