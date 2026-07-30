-- Immutable numeric outcomes for base-screen and focus comparisons.

local immutable_enum = require('dwarfspec.immutable_enum')

---@enum DwarfSpecEBaseScreenFocusComparison
return immutable_enum.define_numeric({
    SAME=1,
    CHANGED=2,
    UNAVAILABLE=3,
})
