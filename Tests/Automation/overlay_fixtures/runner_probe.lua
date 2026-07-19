--@ module=true

local widgets = require('gui.widgets')

---@class tests.AutomationRunnerProbeOverlay: gui.widgets.Label
local AutomationRunnerProbeOverlay = defclass(nil, widgets.Label)
AutomationRunnerProbeOverlay.ATTRS{
    text='automation runner probe',
    default_pos={x=1, y=1},
    default_enabled=false,
    viewscreens='dwarfmode',
    frame={w=1, h=1},
}

OVERLAY_WIDGETS = {runner_probe=AutomationRunnerProbeOverlay}
