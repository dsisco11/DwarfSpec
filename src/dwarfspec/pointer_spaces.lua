-- Immutable identifiers for supported pointer coordinate spaces.

local immutable_enum = require('dwarfspec.support.immutable_enum')

---@enum DwarfSpecEPointerSpace
return immutable_enum.define_numeric({
    GRID=1,
    PIXELS=2,
    WORLD_TILE=3,
})
