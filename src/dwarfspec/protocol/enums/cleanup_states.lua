-- Closed cleanup transaction state vocabulary.

local immutable_enum = require('dwarfspec.support.immutable_enum')

---@enum dwarfspec.ECleanupState
return immutable_enum.define({
    PENDING='pending',
    RUNNING='running',
    COMPLETE='complete',
    FAILED='failed',
    ABANDONED='abandoned',
    UNCONFIRMED='unconfirmed',
})

