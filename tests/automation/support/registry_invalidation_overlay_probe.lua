--@ module=true

-- Test-owned overlays for registry invalidation live coverage.

local overlay = require('plugins.overlay')
local widgets = require('gui.widgets')

---@class tests.RegistryInvalidationOverlay: plugins.overlay.OverlayWidget
local RegistryInvalidationOverlay = defclass(nil, overlay.OverlayWidget)
RegistryInvalidationOverlay.ATTRS{
    default_enabled=false,
    default_pos={x=4, y=4},
    viewscreens='dwarfmode',
    frame={w=20, h=4},
}

---Builds one stable named child for registry identity assertions.
function RegistryInvalidationOverlay:init()
    self:addviews{
        widgets.Label{
            view_id='status',
            frame={l=1, t=1, w=16, h=1},
            text='registry probe',
        },
    }
end

---@class tests.RegistryInvalidationReplacement: tests.RegistryInvalidationOverlay
local RegistryInvalidationReplacement = defclass(nil,
    RegistryInvalidationOverlay)
RegistryInvalidationReplacement.ATTRS{
    default_pos={x=30, y=4},
}

OVERLAY_WIDGETS = {
    original=RegistryInvalidationOverlay,
    replacement=RegistryInvalidationReplacement,
}
