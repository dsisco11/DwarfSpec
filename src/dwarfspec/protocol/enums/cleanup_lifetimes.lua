-- Closed cleanup lifetime vocabulary.

local immutable_enum = require('dwarfspec.support.immutable_enum')

---@enum dwarfspec.ECleanupLifetime
return immutable_enum.define({
    OWNER='owner',
    COMMAND='command',
})

