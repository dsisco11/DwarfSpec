--@ module=true

-- Run-owned registered overlay used by native-screen acceptance coverage.

local overlay = require('plugins.overlay')
local widgets = require('gui.widgets')

---Returns the active DwarfSpec run when the probe is exercised by automation.
---@return table|nil
local function active_run()
    local registry = dfhack.dwarfspec
    local run_id = registry and registry.active_run_id
    return run_id and registry.runs[run_id] or nil
end

---Records one probe event without retaining UI objects in the run record.
---@param name string
local function record(name)
    local run = active_run()
    if not run then return end
    run.native_overlay_events = run.native_overlay_events or {}
    local events = run.native_overlay_events
    events[name] = (events[name] or 0) + 1
end

---@class tests.NativeScreenOverlayProbe: plugins.overlay.OverlayWidget
local NativeScreenOverlayProbe = defclass(
    nil, overlay.OverlayWidget)
NativeScreenOverlayProbe.ATTRS{
    desc='DwarfSpec native-screen acceptance overlay',
    default_enabled=false,
    default_pos={x=8, y=8},
    viewscreens='dwarfmode',
    overlay_onupdate_max_freq_seconds=0,
    frame={w=24, h=5},
}

---Builds one rendered button that records normal overlay input dispatch.
function NativeScreenOverlayProbe:init()
    self.click_count = 0
    self.input_count = 0
    self.render_count = 0
    self:addviews{
        widgets.EditField{
            view_id='editor',
            frame={l=1, t=0, w=18, h=1},
            text='',
        },
        widgets.HotkeyLabel{
            view_id='accept',
            frame={l=1, t=2, w=18, h=1},
            label='Accept',
            on_activate=self:callback('accept'),
        },
        widgets.Label{
            view_id='status',
            frame={l=1, t=4, w=18, h=1},
            text='clicks: 0',
        },
    }
end

---Records enablement through DFHack's real overlay registry.
function NativeScreenOverlayProbe:overlay_onenable()
    record('enabled')
end

---Records disablement through DFHack's real overlay registry.
function NativeScreenOverlayProbe:overlay_ondisable()
    record('disabled')
end

---Records input before using the normal OverlayWidget dispatch path.
---@param keys table
---@return boolean
function NativeScreenOverlayProbe:onInput(keys)
    self.input_count = self.input_count + 1
    record('input')
    return NativeScreenOverlayProbe.super.onInput(self, keys)
end

---Records a completed render through the normal overlay dispatcher.
---@param dc gui.Painter
function NativeScreenOverlayProbe:render(dc)
    self.render_count = self.render_count + 1
    record('render')
    NativeScreenOverlayProbe.super.render(self, dc)
end

---Updates visible state through the button's ordinary activation callback.
function NativeScreenOverlayProbe:accept()
    self.click_count = self.click_count + 1
    self.subviews.status:setText(('clicks: %d'):format(self.click_count))
    record('accepted')
end

OVERLAY_WIDGETS = {
    native_screen=NativeScreenOverlayProbe,
}
