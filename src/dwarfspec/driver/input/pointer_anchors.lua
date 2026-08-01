-- Immutable anchors for pointer placement within subject bounds.

local immutable_enum = require('dwarfspec.support.immutable_enum')

---@enum DwarfSpecEPointerAnchor
return immutable_enum.define({
    CENTER='center',
    TOP_LEFT='top_left',
    TOP_RIGHT='top_right',
    BOTTOM_LEFT='bottom_left',
    BOTTOM_RIGHT='bottom_right',
})
