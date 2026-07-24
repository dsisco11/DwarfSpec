-- Immutable identifiers for input states.

local immutable_enum = require('dwarfspec.immutable_enum')

---@enum DwarfSpecEInputState
return immutable_enum.define({
    CLICK='click',
    DOWN='down',
    UP='up',
})
