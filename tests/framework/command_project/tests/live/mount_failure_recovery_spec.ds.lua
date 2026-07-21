-- Deliberate failed example followed by live mount leak verification.

local widgets = require('gui.widgets')

---@class tests.ExampleRecoveryWidget: widgets.Panel
local ExampleRecoveryWidget = defclass(nil, widgets.Panel)
ExampleRecoveryWidget.ATTRS{
    frame={w=24, h=5},
}

---Creates one selectable child for the failed example.
function ExampleRecoveryWidget:init()
    self:addviews{
        widgets.Label{
            view_id='selected',
            frame={l=1, t=1, w=20},
            text='selected',
        },
    }
end

local failed_subject
local failed_screen
local original_pointer
local original_pause

describe('mounted failed-example recovery', function()
    it('fails while component resources are active', function()
        original_pointer = dfhack.screen.getMousePos
        original_pause = df.global.pause_state
        failed_subject = ds.mount(ExampleRecoveryWidget)
        failed_screen = failed_subject:raw().parent_view
        ds.get('selected'):move_pointer()

        assert.equals('expected', 'deliberate assertion failure')
    end)

    it('starts with no mount, subject, screen, pointer, or pause leak',
            function()
        assert.is_false(failed_screen:isActive())
        assert.is_nil(rawget(failed_screen, 'onRender'))
        assert.equals(original_pointer, dfhack.screen.getMousePos)
        assert.equals(original_pause, df.global.pause_state)
        assert.has_error(function() ds.root() end,
            'DwarfSpec root requires a mounted component; call ' ..
                'ds.mount(component, options) first')
        local available, stale_error = pcall(failed_subject.raw,
            failed_subject)
        assert.is_false(available)
        assert.matches('no component is currently mounted', stale_error,
            1, true)
    end)
end)
