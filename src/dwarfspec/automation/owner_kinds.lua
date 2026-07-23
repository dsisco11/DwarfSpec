-- Immutable identifiers for automation run ownership lifetimes.

local immutable_enum = require('dwarfspec.immutable_enum')

---@enum DwarfSpecOwnerKind
return immutable_enum.define({
    EXTERNAL='external',
    IN_PROCESS='in_process',
})
