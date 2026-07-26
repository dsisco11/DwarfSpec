-- Immutable identifiers for supported pointer coordinate spaces.

local immutable_enum = require('dwarfspec.immutable_enum')

---@enum DwarfSpecEPointerSpace
return immutable_enum.define({
    GRID='grid',
    PIXELS='pixels',
})
