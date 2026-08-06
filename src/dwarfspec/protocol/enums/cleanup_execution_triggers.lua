-- Closed cleanup execution-trigger vocabulary.

local immutable_enum = require('dwarfspec.support.immutable_enum')

---@enum dwarfspec.ECleanupExecutionTrigger
return immutable_enum.define({
    MANUAL='manual',
    COMMAND_FINALLY='command_finally',
    OWNER_TEARDOWN='owner_teardown',
})
