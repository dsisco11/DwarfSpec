--@ module=true

local overlay = require('plugins.overlay')

---@class tests.CommandRunnerProbeOverlay: plugins.overlay.OverlayWidget
local CommandRunnerProbeOverlay = defclass(nil, overlay.OverlayWidget)
CommandRunnerProbeOverlay.ATTRS{
    desc='DwarfSpec command runner probe',
    text='DwarfSpec command runner probe',
    default_pos={x=1, y=1},
    default_enabled=false,
    viewscreens='dwarfmode',
    frame={w=1, h=1},
}

OVERLAY_WIDGETS = {runner_probe=CommandRunnerProbeOverlay}
