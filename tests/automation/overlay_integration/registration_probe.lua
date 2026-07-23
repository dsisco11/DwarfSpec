--@ module=true

local overlay = require('plugins.overlay')

---Records one run-owned lifecycle event without persisting product state.
---@param name string
local function record(name)
local registry = dfhack.dwarfspec
local run = registry and registry.active_run_id and
    registry.runs[registry.active_run_id]
    if not run then return end
    run.overlay_registration_events = run.overlay_registration_events or {}
    local events = run.overlay_registration_events
    events[name] = (events[name] or 0) + 1
end

---@class tests.BroadRegistrationProbe: overlay.OverlayWidget
local BroadRegistrationProbe = defclass(nil, overlay.OverlayWidget)
BroadRegistrationProbe.ATTRS{
    desc='DwarfSpec broad overlay registration probe',
    default_enabled=false,
    default_pos={x=2, y=3},
    viewscreens='dwarfmode',
    overlay_onupdate_max_freq_seconds=0,
    frame={w=2, h=1},
}

---Records real overlay-framework enablement.
function BroadRegistrationProbe:overlay_onenable()
    record('broad_enabled')
end

---Records real overlay-framework disablement.
function BroadRegistrationProbe:overlay_ondisable()
    record('broad_disabled')
end

---Records real viewscreen updates accepted by broad screen matching.
function BroadRegistrationProbe:overlay_onupdate()
    self.update_count = (self.update_count or 0) + 1
end

---@class tests.FilteredRegistrationProbe: overlay.OverlayWidget
local FilteredRegistrationProbe = defclass(nil, overlay.OverlayWidget)
FilteredRegistrationProbe.ATTRS{
    desc='DwarfSpec focus-filtered overlay registration probe',
    default_enabled=false,
    default_pos={x=3, y=4},
    viewscreens='dwarfmode/DwarfSpecIntegrationNeverMatches',
    overlay_onupdate_max_freq_seconds=0,
    frame={w=2, h=1},
}

---Records real overlay-framework enablement for the filtered widget.
function FilteredRegistrationProbe:overlay_onenable()
    record('filtered_enabled')
end

---Records real overlay-framework disablement for the filtered widget.
function FilteredRegistrationProbe:overlay_ondisable()
    record('filtered_disabled')
end

---Records updates only if DFHack's real focus filter admits this widget.
function FilteredRegistrationProbe:overlay_onupdate()
    self.update_count = (self.update_count or 0) + 1
end

OVERLAY_WIDGETS = {
    broad=BroadRegistrationProbe,
    filtered=FilteredRegistrationProbe,
}
