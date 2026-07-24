-- Immutable identifiers for pointer-position mouse input.

local immutable_enum = require('dwarfspec.immutable_enum')

---@enum DwarfSpecMouseInput
return immutable_enum.define({
    LEFT_CLICK='left_click',
    LEFT_DOWN='left_down',
    LEFT_UP='left_up',
    RIGHT_CLICK='right_click',
    RIGHT_DOWN='right_down',
    RIGHT_UP='right_up',
    MIDDLE_CLICK='middle_click',
    MIDDLE_DOWN='middle_down',
    MIDDLE_UP='middle_up',
    SCROLL_UP='scroll_up',
    SCROLL_DOWN='scroll_down',
})
