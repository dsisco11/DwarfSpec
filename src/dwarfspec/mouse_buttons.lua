-- Immutable identifiers for supported mouse buttons and wheel directions.

local immutable_enum = require('dwarfspec.immutable_enum')

---@enum DwarfSpecEMouseButton
return immutable_enum.define({
    LEFT='left',
    RIGHT='right',
    MIDDLE='middle',
    SCROLL_UP='scroll_up',
    SCROLL_DOWN='scroll_down',
})
