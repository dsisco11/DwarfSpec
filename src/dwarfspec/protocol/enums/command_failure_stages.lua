-- Closed command failure-stage vocabulary.

local immutable_enum = require('dwarfspec.support.immutable_enum')

---@enum dwarfspec.ECommandFailureStage
return immutable_enum.define({
    NORMALIZATION='normalization',
    PREFLIGHT='preflight',
    CLAIM_PLANNING='claim_planning',
    EXECUTION='execution',
    CLEANUP_REGISTRATION='cleanup_registration',
    INTRINSIC_VERIFICATION='intrinsic_verification',
    CALLER_VERIFICATION='caller_verification',
    COMMAND_CLEANUP='command_cleanup',
    RESULT_PROJECTION='result_projection',
})

