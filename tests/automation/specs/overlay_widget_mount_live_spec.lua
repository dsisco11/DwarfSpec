-- Product-independent live proof for isolated overlay component mounting.

local gui = require('gui')
local widgets = require('gui.widgets')
local overlay = require('plugins.overlay')

---@class tests.OverlayWidgetHarness: overlay.OverlayWidget
local OverlayWidgetHarness = defclass(nil, overlay.OverlayWidget)
OverlayWidgetHarness.ATTRS{
    default_pos={x=3, y=4},
    frame={w=28, h=5},
    full_interface=true,
    overlay_onupdate_max_freq_seconds=0,
}

---Creates interactive content and instance-bound enable/disable callbacks.
function OverlayWidgetHarness:init()
    self.events = {}
    self.update_count = 0
    self.input_count = 0
    self.render_count = 0
    self.overlay_onenable = function()
        table.insert(self.events, 'enable')
    end
    self.overlay_ondisable = function()
        table.insert(self.events, 'disable')
    end
    self:addviews{
        widgets.HotkeyLabel{
            view_id='submit',
            frame={l=0, t=0, w=12},
            label='Submit',
            on_activate=self:callback('submit'),
        },
        widgets.Label{
            view_id='status',
            frame={l=0, t=2, w=24},
            text='pending',
        },
    }
end

---Records the backing viewscreen supplied by the isolated lifecycle.
---@param viewscreen userdata
function OverlayWidgetHarness:overlay_onupdate(viewscreen)
    self.update_count = self.update_count + 1
    self.last_update_viewscreen = viewscreen
    table.insert(self.events, 'update')
end

---Records input before delegating to ordinary widget dispatch.
---@param keys table
---@return boolean
function OverlayWidgetHarness:onInput(keys)
    self.input_count = self.input_count + 1
    table.insert(self.events, 'input')
    return OverlayWidgetHarness.super.onInput(self, keys)
end

---Records the painter bounds used for isolated overlay rendering.
---@param dc gui.Painter
function OverlayWidgetHarness:render(dc)
    self.render_count = self.render_count + 1
    self.last_painter = {
        x1=dc.x1,
        y1=dc.y1,
        width=dc.width,
        height=dc.height,
    }
    table.insert(self.events, 'render')
    OverlayWidgetHarness.super.render(self, dc)
end

---Applies a visible state change through a normal child callback.
function OverlayWidgetHarness:submit()
    self.subviews.status:setText('saved')
end

describe('overlay widget component host', function()
    it('mounts a class with scaled lifecycle, interaction, and cleanup',
            function()
        local backing = dfhack.gui.getCurViewscreen(true)
        local root = ds.mount(OverlayWidgetHarness, {
            backing_viewscreen=backing,
            overlay_position={x=6, y=7},
        })
        local instance = root:raw()
        local scaled = gui.ViewRect{rect=gui.get_interface_rect()}

        assert.matches('^dwarfspec%.', instance.name)
        assert.equals(5, instance.frame.l)
        assert.equals(6, instance.frame.t)
        assert.equals('enable', instance.events[1])
        assert.equals(scaled.x1, instance.last_painter.x1)
        assert.equals(scaled.y1, instance.last_painter.y1)
        assert.equals(scaled.width, instance.last_painter.width)
        assert.equals(scaled.height, instance.last_painter.height)

        ds.wait_frames(2)
        assert.is_true(instance.update_count > 0)
        assert.equals(backing, instance.last_update_viewscreen)
        ds.click(ds.get('submit'))
        assert.equals('saved', ds.inspect(ds.get('status')).text)
        assert.is_true(instance.input_count > 0)

        local updates = instance.update_count
        local renders = instance.render_count
        instance.active = false
        ds.wait_frames(2)
        assert.equals(updates, instance.update_count)
        assert.is_true(instance.render_count > renders)

        instance.active = true
        instance.visible = false
        renders = instance.render_count
        ds.wait_frames(2)
        assert.equals(renders, instance.render_count)
        instance.visible = true
        ds.wait_frames(1)
        ds.unmount()
        assert.equals('disable', instance.events[#instance.events])
        assert.is_nil(instance.name)
    end)

    it('mounts a fullscreen existing instance with throttled updates',
            function()
        local instance = OverlayWidgetHarness{
            fullscreen=true,
            full_interface=false,
            overlay_onupdate_max_freq_seconds=60,
        }
        local original_frame = instance.frame
        local width, height = dfhack.screen.getWindowSize()
        ds.mount(instance, {overlay_position={x=-2, y=-3}})

        assert.equals(1, instance.frame.r)
        assert.equals(2, instance.frame.b)
        assert.equals(width, instance.last_painter.width)
        assert.equals(height, instance.last_painter.height)
        ds.wait_frames(3)
        assert.is_true(instance.update_count <= 1)
        ds.unmount()
        assert.equals(original_frame, instance.frame)
        assert.is_nil(instance.name)
        assert.equals('disable', instance.events[#instance.events])
    end)
end)
