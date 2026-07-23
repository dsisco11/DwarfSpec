-- Immutable string enum for classified external runner outcomes.

local immutable_enum = require('dwarfspec.immutable_enum')

---@enum DwarfSpecRunnerFailureKind
return immutable_enum.define({
    SUCCESS='success',
    USAGE='usage',
    DEPENDENCY='dependency',
    CONNECTION='connection',
    REGISTRATION='registration',
    EXECUTOR_QUARANTINED='executor_quarantined',
    HOST='host',
    TEST='test',
    TIMEOUT='timeout',
    QUEUE_TIMEOUT='queue_timeout',
    ABORTED='aborted',
    CANCELLED='cancelled',
})
