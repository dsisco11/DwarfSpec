-- Immutable string enum for classified scheduler outcomes.

local immutable_enum = require('dwarfspec.immutable_enum')

---@enum DwarfSpecSchedulerFailureKind
return immutable_enum.define({
    PROJECT_BUSY='project_busy',
    REQUEST_KEY_CONFLICT='request_key_conflict',
    RESULT_PATH_BUSY='result_path_busy',
    EXECUTOR_BUSY='executor_busy',
    EXECUTOR_QUARANTINED='executor_quarantined',
    ACTIVATION_INVALID='activation_invalid',
})
