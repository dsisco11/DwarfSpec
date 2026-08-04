-- Production-shaped TestBed consumer widget used by live automation.

local widgets = require('gui.widgets')
local dependency = require('testbed_live.dependency')
local script_state = dfhack.reqscript('testbed_live/state')
local probe = require('testbed_live.probe')
local observer = require('testbed_live.observer')

---@class tests.TestBedLiveWidget: widgets.Panel
local TestBedLiveWidget = defclass(nil, widgets.Panel)
TestBedLiveWidget.ATTRS{
    view_id='testbed_live_root',
    frame={w=48, h=8},
}

---Constructs interactive content from module and script dependencies.
function TestBedLiveWidget:init()
    self.module_identity = dependency.identity
    self.script_identity = script_state.identity
    self.module_replacement = dependency.replacement
    self.script_replacement = script_state.replacement
    self:addviews{
        widgets.HotkeyLabel{
            view_id='activate',
            frame={l=1, t=1, w=18},
            label='Activate',
            on_activate=self:callback('activate'),
        },
        widgets.Label{
            view_id='status',
            frame={l=1, t=3, w=44},
            text='pending',
        },
    }
end

---Publishes the configured dependency values through rendered widget state.
function TestBedLiveWidget:activate()
    local status = ('active:%s:%s'):format(
        self.module_replacement.text,
        self.script_replacement.text)
    self.subviews.status:setText(status)
    observer.record(status)
end

---@class tests.TestBedLiveFailingWidget: widgets.Panel
local TestBedLiveFailingWidget = defclass(nil, widgets.Panel)
TestBedLiveFailingWidget.ATTRS{
    frame={w=24, h=4},
}

---Captures a bed-owned loader and then deliberately fails construction.
function TestBedLiveFailingWidget:init()
    probe.constructor_started = true
    probe.retained_require = require
    error('intentional TestBed live constructor failure')
end

return {
    Widget=TestBedLiveWidget,
    FailingWidget=TestBedLiveFailingWidget,
}
