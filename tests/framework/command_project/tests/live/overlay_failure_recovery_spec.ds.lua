-- Deliberate failed overlay example followed by lifecycle-order verification.

local overlay = require('plugins.overlay')
local widgets = require('gui.widgets')

---@class tests.OverlayRecoveryWidget: overlay.OverlayWidget
local OverlayRecoveryWidget = defclass(nil, overlay.OverlayWidget)
OverlayRecoveryWidget.ATTRS{
    default_pos={x=3, y=4},
    frame={w=24, h=5},
}

---Creates callbacks that observe cleanup ordering from the component.
function OverlayRecoveryWidget:init()
    self.overlay_onenable = function()
        self.enabled_called = true
    end
    self.overlay_ondisable = function()
        self.disabled_called = true
        self.disable_screen_active = self.parent_view:isActive()
        self.disable_render_installed =
            rawget(self.parent_view, 'onRender') ~= nil
    end
    self:addviews{
        widgets.Label{
            view_id='selected',
            frame={l=1, t=1, w=20},
            text='selected',
        },
    }
end

local instance
local owned_screen
local original_frame
local original_pointer
local original_pause

describe('failed overlay lifecycle recovery', function()
    it('01 fails with overlay resources active', function()
        instance = OverlayRecoveryWidget{}
        original_frame = instance.frame
        original_pointer = dfhack.screen.getMousePos
        original_pause = df.global.pause_state
        ds.mount(instance, {overlay_position={x=8, y=9}})
        owned_screen = instance.parent_view
        ds.get('selected'):move_pointer()

        assert.is_true(instance.enabled_called)
        assert.equals('expected', 'deliberate overlay assertion failure')
    end)

    it('02 restores lifecycle resources in reverse ownership order',
            function()
        assert.is_true(instance.disabled_called)
        assert.is_true(instance.disable_screen_active)
        assert.is_true(instance.disable_render_installed)
        assert.is_false(owned_screen:isActive())
        assert.is_nil(rawget(owned_screen, 'onRender'))
        assert.equals(original_frame, instance.frame)
        assert.is_nil(instance.name)
        assert.equals(original_pointer, dfhack.screen.getMousePos)
        assert.equals(original_pause, df.global.pause_state)
        assert.has_error(function() ds.root() end,
            'DwarfSpec root requires a mounted component; call ' ..
                'ds.mount(component, options) first')
    end)
end)
