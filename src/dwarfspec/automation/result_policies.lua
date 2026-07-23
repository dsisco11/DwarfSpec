-- Immutable string enum for project result-persistence policies.

local immutable_enum = require('dwarfspec.immutable_enum')

---@enum DwarfSpecResultPolicy
return immutable_enum.define({
    FILE='file',
    NONE='none',
})
