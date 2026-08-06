-- Closed cleanup terminal-disposition vocabulary.

local immutable_enum = require('dwarfspec.support.immutable_enum')

---@enum dwarfspec.ECleanupTerminalDisposition
return immutable_enum.define({
    COMPLETE='complete',
    FAILED='failed',
    ABANDONED='abandoned',
    UNCONFIRMED='unconfirmed',
})

