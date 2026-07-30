-- Product-independent live proof for isolated overlay component mounting.

local gui = require('gui')
local widgets = require('gui.widgets')
local overlay = require('plugins.overlay')
local command_conformance = require(
    'tests.automation.support.command_conformance')

local OVERLAY_CAPABILITIES = command_conformance.new{
    root_inspection=true,
    tree_capture=true,
    screen_capture=true,
    subject_pointer_placement=true,
    subject_hover=true,
    keyboard_input=true,
    text_input=true,
    physical_mouse_states=true,
    default_wait_redraw=true,
    no_wait_redraw=true,
    viewport='supported',
}

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

---@class tests.OverlayInputBacking: gui.ZScreen
local OverlayInputBacking = defclass(nil, gui.ZScreen)
OverlayInputBacking.ATTRS{
    focus_path='dwarfspec/overlay-input-backing',
    initial_pause=false,
}

---Initializes backing-screen input observations without interactive controls.
function OverlayInputBacking:init()
    self.input_count = 0
    self.custom_input_count = 0
    self.unexpected_command_count = 0
end

---Records sentinel fallthrough and commands that should remain overlay-owned.
---@param keys table
---@return boolean
function OverlayInputBacking:onInput(keys)
    self.input_count = self.input_count + 1
    if keys.CUSTOM_B then
        self.custom_input_count = self.custom_input_count + 1
        return true
    end
    local has_text = keys._STRING and keys._STRING ~= 0
    if not has_text then
        for key in pairs(keys) do
            if type(key) == 'string' and key:match('^STRING_A%d%d%d$') then
                has_text = true
                break
            end
        end
    end
    if keys.CUSTOM_A or keys._MOUSE_L or has_text then
        self.unexpected_command_count = self.unexpected_command_count + 1
    end
    return OverlayInputBacking.super.onInput(self, keys)
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
    frame={w=28, h=10},
    full_interface=true,
    overlay_onupdate_max_freq_seconds=0,
}

---Creates interactive content and instance-bound enable/disable callbacks.
function OverlayWidgetHarness:init()
    self.events = {}
    self.update_count = 0
    self.input_count = 0
    self.render_count = 0
    self.custom_input_count = 0
    self.pointer_click_count = 0
    self.pointer_down_count = 0
    self.pointer_up_count = 0
    self.physical_events = {}
    self.overlay_onenable = function()
        table.insert(self.events, 'enable')
    end
    self.overlay_ondisable = function()
        table.insert(self.events, 'disable')
    end
    self:addviews{
        widgets.EditField{
            view_id='editor',
            frame={l=0, t=0, w=24},
            text='',
        },
        widgets.HotkeyLabel{
            view_id='submit',
            frame={l=0, t=2, w=12},
            label='Submit',
            on_activate=self:callback('submit'),
        },
        widgets.Label{
            view_id='status',
            frame={l=0, t=4, w=24},
            text='pending',
        },
        widgets.Label{
            view_id='pointer_target',
            frame={l=0, t=6, w=24, h=2},
            text='Rendered pointer target',
        },
    }
end

---Returns whether the live pointer lies inside the rendered target.
---@return boolean
function OverlayWidgetHarness:isPointerOverTarget()
    local x, y = dfhack.screen.getMousePos()
    local body = self.subviews.pointer_target.frame_body
    return x ~= nil and y ~= nil and body ~= nil and
        body:inClipGlobalXY(x, y)
end

---Records one physical dispatch with its temporary DF input state.
---@param kind string
function OverlayWidgetHarness:recordPhysicalEvent(kind)
    local x, y = dfhack.screen.getMousePos()
    table.insert(self.physical_events, {
        kind=kind,
        x=x,
        y=y,
        mouse_focus=df.global.enabler.mouse_focus,
        tracking_on=df.global.enabler.tracking_on,
        mouse_lbut_down=df.global.enabler.mouse_lbut_down,
        mouse_lbut_lift=df.global.enabler.mouse_lbut_lift,
    })
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
    if keys.CUSTOM_A then
        self.custom_input_count = self.custom_input_count + 1
        return true
    end
    if keys._MOUSE_L and self:isPointerOverTarget() then
        self.pointer_click_count = self.pointer_click_count + 1
        self:recordPhysicalEvent('click')
        return true
    end
    if keys._MOUSE_L_DOWN then
        self.pointer_down_count = self.pointer_down_count + 1
        self:recordPhysicalEvent('down')
        return true
    end
    if df.global.enabler.mouse_lbut_lift == 1 then
        self.pointer_up_count = self.pointer_up_count + 1
        self:recordPhysicalEvent('up')
        return true
    end
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
    it('inspects DFHack list scroll state', function()
        ds.mount(MouseInputBacking)
        local list = ds.get('native_list')
        local raw = list:raw()
        local state = list:inspect()

        assert.equals(raw.page_top, state.scroll_position)
        assert.equals(raw.page_size, state.visible_row_count)
        assert.is_nil(state.choices)
    end)

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

            target:mouseWheel({
                direction=ds.EMouseButton.SCROLL_DOWN,
                steps=2,
                anchor='top_left',
            })
            assert.equals(2, instance.wheel_count)
            assert.equals(0, backing.wheel_count)
            assert.equals(1, list.page_top,
                'native list row movement is render-coalesced')

            instance.consume_wheel = false
            ds.mouseInput(ds.EMouseButton.SCROLL_DOWN)
            assert.equals(3, instance.wheel_count)
            assert.equals(1, backing.wheel_count)
            assert.equals(2, list.page_top,
                'native list row movement is render-coalesced')
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

    it('routes keyboard, text, and physical mouse input overlay-first',
            function()
        local original_screen = dfhack.gui.getCurViewscreen(true)
        local original_focus = dfhack.gui.getFocusStrings(original_screen)
        local initial_pointer = command_conformance.pointer_snapshot()
        local backing = OverlayInputBacking{}
        backing:show()
        local mounted = false
        local instance
        local ok, failure = xpcall(function()
            local root = ds.mount(OverlayWidgetHarness, {
                backing_viewscreen=backing._native,
            })
            mounted = true
            instance = root:raw()
            local editor = ds.get('editor')
            local target = ds.get('pointer_target')

            editor:click()
            assert.is_true(editor:inspect().focused)
            ds.input('CUSTOM_A')
            assert.equals(1, instance.custom_input_count)
            assert.equals(0, backing.unexpected_command_count)

            editor:type('overlay')
            assert.equals('overlay', editor:text())
            assert.equals(0, backing.unexpected_command_count)

            target:hover()
            assert.is_true(instance:isPointerOverTarget())
            ds.mouseInput(ds.EMouseButton.LEFT)
            assert.equals(1, instance.pointer_click_count)
            assert.equals('click', instance.physical_events[1].kind)
            assert.is_true(instance.physical_events[1].mouse_focus)
            assert.equals(1, instance.physical_events[1].tracking_on)

            target:hover()
            local down_event_start = #instance.physical_events + 1
            ds.mouseInput(ds.EMouseButton.LEFT, ds.EInputState.DOWN)
            local down
            for index=down_event_start,#instance.physical_events do
                local candidate = instance.physical_events[index]
                if candidate.mouse_lbut_down == 1 and
                        candidate.mouse_focus and candidate.tracking_on == 1 then
                    down = candidate
                    break
                end
            end
            assert.is_truthy(down,
                'DOWN dispatch must expose temporary button ownership')
            assert.equals('down', down.kind)
            assert.equals(0, down.mouse_lbut_lift)
            assert.is_true(target:raw().frame_body:
                inClipGlobalXY(down.x, down.y))
            assert.equals(1, df.global.enabler.mouse_lbut_down)

            assert.is_true(instance:isPointerOverTarget())
            local up_event_start = #instance.physical_events + 1
            ds.mouseInput(ds.EMouseButton.LEFT, ds.EInputState.UP)
            local up
            for index=up_event_start,#instance.physical_events do
                local candidate = instance.physical_events[index]
                if candidate.mouse_lbut_lift == 1 and
                        candidate.mouse_focus and candidate.tracking_on == 1 then
                    up = candidate
                    break
                end
            end
            assert.is_truthy(up,
                'UP dispatch must expose temporary lift ownership')
            assert.equals('up', up.kind)
            assert.equals(0, up.mouse_lbut_down)
            assert.is_true(target:raw().frame_body:
                inClipGlobalXY(up.x, up.y))
            assert.equals(0, df.global.enabler.mouse_lbut_down)
            assert.equals(0, df.global.enabler.mouse_lbut_lift)
            assert.equals(0, backing.unexpected_command_count)

            local backing_input_count = backing.input_count
            ds.input('CUSTOM_B')
            assert.equals(backing_input_count + 1, backing.input_count)
            assert.equals(1, backing.custom_input_count,
                'declined overlay input must reach the backing screen once')
        end, debug.traceback)

        local unmounted, unmount_failure = true, nil
        if mounted then
            unmounted, unmount_failure = pcall(ds.unmount)
        end
        local overlay_cleaned = instance == nil or instance.name == nil
        local backing_revealed = backing:isActive()
        if backing_revealed then backing:dismiss() end
        assert.is_true(unmounted, unmount_failure)
        assert.is_true(overlay_cleaned,
            'unmount must remove the isolated overlay registration')
        assert.is_true(backing_revealed,
            'unmount must reveal the native backing screen')
        assert.is_false(backing:isActive(),
            'native backing screen must be dismissed during cleanup')
        assert.equals(original_screen, dfhack.gui.getCurViewscreen(true))
        assert.same(original_focus, dfhack.gui.getFocusStrings(original_screen))
        command_conformance.assert_pointer_restored(
            initial_pointer, command_conformance.pointer_snapshot())
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

        command_conformance.assert_mounted_root(root, instance)
        command_conformance.assert_mounted_root(ds.root(), instance)
        OVERLAY_CAPABILITIES:assert_clean()
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
        instance.active = false
        ds.wait_frames(2)
        assert.equals(updates, instance.update_count)
        local cases = {
            {visible=true, active=true, should_render=true},
            {visible=true, active=false, should_render=true},
            {visible=false, active=true, should_render=false},
            {visible=false, active=false, should_render=false},
        }
        for _, case in ipairs(cases) do
            instance.visible = case.visible
            instance.active = case.active
            local renders = instance.render_count

            root:redraw()

            if case.should_render then
                assert.is_true(instance.render_count > renders,
                    ('visible=%s active=%s should render'):format(
                        tostring(case.visible), tostring(case.active)))
            else
                assert.equals(renders, instance.render_count,
                    ('visible=%s active=%s should not render'):format(
                        tostring(case.visible), tostring(case.active)))
            end
        end

        instance.active = true
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
