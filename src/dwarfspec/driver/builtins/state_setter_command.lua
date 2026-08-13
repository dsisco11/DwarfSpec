-- Shared verified state-setter definition mechanics.

local CleanupLifetime = require(
    'dwarfspec.protocol.enums.cleanup_lifetimes')
local CommandKind = require('dwarfspec.protocol.enums.command_kinds')
local Definition = require('dwarfspec.driver.command.definition')
local IntrinsicKind = require(
    'dwarfspec.protocol.enums.intrinsic_verification_kinds')
local Outcomes = require('dwarfspec.driver.command.outcomes')
local RetryPolicy = require(
    'dwarfspec.protocol.enums.execution_retry_policies')

---@class dwarfspec.StateSetterCommandBuilder
---@field private _spec table
local StateSetterCommand = {}
StateSetterCommand.__index = StateSetterCommand

---Creates shared mechanics for one command-specific owner.
---@param spec table
---@return dwarfspec.StateSetterCommandBuilder
function StateSetterCommand.new(spec)
    assert(type(spec) == 'table', 'state-setter specification is required')
    for _, name in ipairs({'name', 'normalize', 'preflight', 'execute',
            'verify', 'restore', 'verify_restored'}) do
        local expected = name == 'name' and 'string' or 'function'
        assert(type(spec[name]) == expected,
            'state-setter specification requires ' .. name)
    end
    return setmetatable({_spec=spec}, StateSetterCommand)
end

---Builds an immutable verified state-setter definition.
---@return table
function StateSetterCommand:build_definition()
    local spec = self._spec
    return Definition.validate({name=spec.name, kind=CommandKind.STATE_SETTER,
        normalize=function(arguments) return spec.normalize(arguments) end,
        preflight=function(context, request)
            return Outcomes.ready(spec.preflight(request))
        end,
        execute=function(context, request, readiness)
            return spec.execute(request, readiness)
        end,
        verify=function(context, request, receipt)
            return spec.verify(request, receipt)
        end,
        cleanup={lifetime=CleanupLifetime.OWNER,
            restore=function(context, receipt)
                return spec.restore(receipt)
            end,
            verify=function(context, receipt)
                return spec.verify_restored(receipt)
            end},
        execution_retry_policy=RetryPolicy.ONCE,
        intrinsic_verification=IntrinsicKind.CALLBACK})
end

return StateSetterCommand
