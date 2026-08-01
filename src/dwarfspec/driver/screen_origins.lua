-- Immutable anchors for map tiles positioned within the visible map viewport.

local immutable_enum = require('dwarfspec.support.immutable_enum')

---@enum DwarfSpecEScreenOrigin
return immutable_enum.define({
    TOP_LEFT='top_left',
    TOP='top',
    TOP_RIGHT='top_right',
    LEFT='left',
    CENTER='center',
    RIGHT='right',
    BOTTOM_LEFT='bottom_left',
    BOTTOM='bottom',
    BOTTOM_RIGHT='bottom_right',
})
