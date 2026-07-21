-- Deliberate mounted wait used to prove terminal cleanup paths.

local widgets = require('gui.widgets')

---@class tests.TerminalCleanupWidget: widgets.Panel
local TerminalCleanupWidget = defclass(nil, widgets.Panel)
TerminalCleanupWidget.ATTRS{
    frame={w=24, h=5},
}

---Creates one ordinary child so selection and pointer cleanup are exercised.
function TerminalCleanupWidget:init()
    self:addviews{
        widgets.Label{
            view_id='waiting',
            frame={l=1, t=1, w=20},
            text='waiting',
        },
    }
end

describe('mounted terminal cleanup probe', function()
    it('remains mounted until an external terminal action', function()
        ds.mount(TerminalCleanupWidget)
        ds.get('waiting'):move_pointer()
        ds.await('deliberate mounted terminal wait', function()
            return false
        end, {frame_budget=100000, timeout_ms=60000})
    end)
end)
