-- Immutable string enum for classified external runner outcomes.

local immutable_enum = require('dwarfspec.immutable_enum')

---@enum DwarfSpecRunnerFailureKind
return immutable_enum.define({
    SUCCESS='success',
    USAGE='usage',
    DEPENDENCY='dependency',
    CONNECTION='connection',
    HOST='host',
    TEST='test',
    TIMEOUT='timeout',
    ABORTED='aborted',
})
