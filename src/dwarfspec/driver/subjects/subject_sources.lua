-- Immutable identifiers for mounted subject-source selection.

local immutable_enum = require('dwarfspec.support.immutable_enum')

---@enum DwarfSpecESubjectSource
return immutable_enum.define({
    NATIVE='native',
    OVERLAY='overlay',
})
