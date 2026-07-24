-- Product-independent live proof for isolated overlay component mounting.

local gui = require('gui')
local widgets = require('gui.widgets')
local overlay = require('plugins.overlay')

---@class tests.MouseInputBacking: gui.ZScreen
local MouseInputBacking = defclass(nil, gui.ZScreen)
MouseInputBacking.ATTRS{
    focus_path='dwarfspec/mouse-input-backing',
    initial_pause=false,
}

---Creates the native list used to prove pointer-dependent wheel routing.
function MouseInputBacking:init()
    self.wheel_count = 0
    local choices = {}
    for index=1,12 do
        table.insert(choices, ('Native row %02d'):format(index))
    end
    self:addviews{
        widgets.List{
            view_id='native_list',
            frame={l=8, t=8, w=24, h=4},
            choices=choices,
        },
    }
end

---Counts wheel input delivered to the backing screen before normal dispatch.
---@param keys table
---@return boolean
function MouseInputBacking:onInput(keys)
    if keys.CONTEXT_SCROLL_DOWN then
        self.wheel_count = self.wheel_count + 1
    end
    return MouseInputBacking.super.onInput(self, keys)
end

---@class tests.MouseInputOverlay: overlay.OverlayWidget
local MouseInputOverlay = defclass(nil, overlay.OverlayWidget)
MouseInputOverlay.ATTRS{
    default_pos={x=1, y=1},
    frame={w=40, h=20},
    full_interface=true,
    overlay_onupdate_max_freq_seconds=0,
}

---Creates a transparent pointer target aligned with the native list.
function MouseInputOverlay:init()
    self.consume_wheel = true
    self.wheel_count = 0
    self:addviews{
        widgets.Panel{
            view_id='native_list_pointer_target',
            frame={l=8, t=8, w=24, h=4},
        },
    }
end

---Consumes configured wheel input before otherwise delegating normally.
---@param keys table
---@return boolean
function MouseInputOverlay:onInput(keys)
    if keys.CONTEXT_SCROLL_DOWN then
        self.wheel_count = self.wheel_count + 1
        if self.consume_wheel then return true end
    end
    return MouseInputOverlay.super.onInput(self, keys)
end

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
    it('routes positioned wheel input overlay-first and falls through once',
            function()
        local backing = MouseInputBacking{}
        backing:show()
        local mounted = false
        local ok, failure = xpcall(function()
            local window_width, window_height =
                dfhack.screen.getWindowSize()
            local root = ds.mount(MouseInputOverlay, {
                backing_viewscreen=backing._native,
                frame={w=window_width, h=window_height},
            })
            mounted = true
            local instance = root:raw()
            local list = backing.subviews.native_list
            local target = ds.get('native_list_pointer_target')
            local target_view = target:raw()
            target_view.frame.l = list.frame_body.x1 - instance.frame_body.x1
            target_view.frame.t = list.frame_body.y1 - instance.frame_body.y1
            target_view:updateLayout()

            target:hover('top_left')
            local pointer_x, pointer_y = dfhack.screen.getMousePos()
            local list_x, list_y = list:getMousePos()
            assert.is_not_nil(list_x,
                ('virtual pointer %s,%s must be over native list %s,%s-%s,%s; ' ..
                    'target=%s,%s-%s,%s overlay=%s,%s-%s,%s')
                    :format(tostring(pointer_x), tostring(pointer_y),
                        list.frame_body.x1, list.frame_body.y1,
                        list.frame_body.x2, list.frame_body.y2,
                        target_view.frame_body.x1, target_view.frame_body.y1,
                        target_view.frame_body.x2, target_view.frame_body.y2,
                        instance.frame_body.x1, instance.frame_body.y1,
                        instance.frame_body.x2, instance.frame_body.y2))
            assert.is_not_nil(list_y,
                'virtual pointer must be over the rendered native list')

            ds.mouseInput(ds.EMouseButton.SCROLL_DOWN)
            assert.equals(1, instance.wheel_count)
            assert.equals(0, backing.wheel_count)
            assert.equals(1, list.page_top)

            instance.consume_wheel = false
            ds.mouseInput(ds.EMouseButton.SCROLL_DOWN)
            assert.equals(2, instance.wheel_count)
            assert.equals(1, backing.wheel_count)
            assert.equals(2, list.page_top)
        end, debug.traceback)

        local unmounted, unmount_failure = true, nil
        if mounted then
            unmounted, unmount_failure = pcall(ds.unmount)
        end
        local backing_revealed = backing:isActive()
        if backing_revealed then backing:dismiss() end
        assert.is_true(unmounted, unmount_failure)
        assert.is_true(backing_revealed,
            'unmount must reveal the native backing screen')
        assert.is_false(backing:isActive(),
            'native backing screen must be dismissed during cleanup')
        assert.is_true(ok, failure)
    end)

    it('mounts a class with scaled lifecycle, interaction, and cleanup',
            function()
        local backing = dfhack.gui.getCurViewscreen(true)
        local root = ds.mount(OverlayWidgetHarness, {
            backing_viewscreen=backing,
            overlay_position={x=6, y=7},
        })
        local instance = root:raw()

        assert.matches('^dwarfspec%.', instance.name)
        assert.equals(5, instance.frame.l)
        assert.equals(6, instance.frame.t)
        assert.equals('enable', instance.events[1])
        assert.equals(0, instance.last_painter.x1)
        assert.equals(0, instance.last_painter.y1)
        assert.equals(128, instance.last_painter.width)
        assert.equals(64, instance.last_painter.height)
        ds.viewport(60, 20)
        assert.equals(60, instance.last_painter.width)
        assert.equals(20, instance.last_painter.height)

        ds.wait_frames(2)
        assert.is_true(instance.update_count > 0)
        assert.equals(backing, instance.last_update_viewscreen)
        ds.get('submit'):click()
        assert.equals('saved', ds.get('status'):inspect().text)
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
        ds.mount(instance, {overlay_position={x=-2, y=-3}})

        assert.equals(1, instance.frame.r)
        assert.equals(2, instance.frame.b)
        assert.equals(128, instance.last_painter.width)
        assert.equals(64, instance.last_painter.height)
        ds.viewport(61, 31)
        assert.equals(61, instance.last_painter.width)
        assert.equals(31, instance.last_painter.height)
        ds.wait_frames(3)
        assert.is_true(instance.update_count <= 1)
        ds.unmount()
        assert.equals(original_frame, instance.frame)
        assert.is_nil(instance.name)
        assert.equals('disable', instance.events[#instance.events])
    end)
end)
