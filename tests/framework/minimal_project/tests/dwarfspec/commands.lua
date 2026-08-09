-- Custom ds command definitions for the minimal consumer proof.

local CommandKind = require('dwarfspec.protocol.enums.command_kinds')
local IntrinsicKind = require(
    'dwarfspec.protocol.enums.intrinsic_verification_kinds')
local RetryPolicy = require(
    'dwarfspec.protocol.enums.execution_retry_policies')
local Outcomes = require('dwarfspec.driver.command.outcomes')

---Returns the immutable minimal-consumer query definition.
---@return table
local function consumer_identity_definition()
    return {
        name='consumer_identity', kind=CommandKind.QUERY,
        normalize=function(arguments) return arguments end,
        preflight=function() return Outcomes.ready(true) end,
        execute=function() return Outcomes.ready('minimal-consumer') end,
        execution_retry_policy=RetryPolicy.ONCE,
        intrinsic_verification=IntrinsicKind.PRIMARY_OBSERVATION,
    }
end

return {
    commands={
        consumer_identity=consumer_identity_definition(),
    },
}
