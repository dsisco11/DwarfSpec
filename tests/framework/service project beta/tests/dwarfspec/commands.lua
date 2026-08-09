-- Project-specific command used by multi-project isolation evidence.

local CommandKind = require('dwarfspec.protocol.enums.command_kinds')
local IntrinsicKind = require('dwarfspec.protocol.enums.intrinsic_verification_kinds')
local RetryPolicy = require('dwarfspec.protocol.enums.execution_retry_policies')
local Outcomes = require('dwarfspec.driver.command.outcomes')

---Returns the owning fixture-project query definition.
---@return table
local function project_identity()
    return {name='project_identity', kind=CommandKind.QUERY,
        normalize=function(arguments) return arguments end,
        preflight=function() return Outcomes.ready(true) end,
        execute=function() return Outcomes.ready('beta') end,
        execution_retry_policy=RetryPolicy.ONCE,
        intrinsic_verification=IntrinsicKind.PRIMARY_OBSERVATION}
end

return {
    commands={
        project_identity=project_identity(),
    },
}
