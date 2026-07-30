-- Product-independent live proof for ordinary widget component mounting.

local widgets = require('gui.widgets')
local command_conformance = require(
    'tests.automation.support.command_conformance')

local ORDINARY_CAPABILITIES = command_conformance.new{
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

---@class tests.OrdinaryWidgetHarness: widgets.Panel
local OrdinaryWidgetHarness = defclass(nil, widgets.Panel)
OrdinaryWidgetHarness.ATTRS{
    view_id='ordinary_root',
    frame={w=50, h=12},
}

---Creates nested interactive content using only normal DFHack widgets.
function OrdinaryWidgetHarness:init()
    self.saw_real_painter = false
    self.render_count = 0
    self.hover_render_count = 0
    self.pointer_click_count = 0
    self.pointer_down_count = 0
    self.pointer_up_count = 0
    self.pointer_wheel_count = 0
    self.custom_input_count = 0
    self.typed_text = ''
    self.physical_events = {}
    self:addviews{
        widgets.Panel{
            view_id='nested_panel',
            frame={l=1, t=1, w=46, h=6},
            subviews={
                widgets.EditField{
                    view_id='editor',
                    frame={l=0, t=0, w=24},
                    text='',
                },
                widgets.HotkeyLabel{
                    view_id='submit',
                    frame={l=0, t=2, w=14},
                    label='Submit',
                    on_activate=self:callback('submit'),
                },
                widgets.Label{
                    view_id='status',
                    frame={l=0, t=4, w=30},
                    text='pending',
                },
            },
        },
        widgets.Label{
            view_id='pointer_target',
            frame={l=2, t=8, w=24, h=2},
            text='Rendered pointer target',
        },
    }
end

---Returns whether the live pointer lies inside the rendered target.
---@return boolean
function OrdinaryWidgetHarness:isPointerOverTarget()
    local x, y = dfhack.screen.getMousePos()
    local body = self.subviews.pointer_target.frame_body
    return x ~= nil and y ~= nil and body ~= nil and
        body:inClipGlobalXY(x, y)
end

---Records one physical dispatch with its temporary DF input state.
---@param kind string
function OrdinaryWidgetHarness:recordPhysicalEvent(kind)
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

---Records that normal rendering supplied a live painter to the component.
---@param dc gui.Painter
function OrdinaryWidgetHarness:onRenderBody(dc)
    self.render_count = self.render_count + 1
    self.saw_real_painter = type(dc) == 'table' and
        type(dc.seek) == 'function'
    OrdinaryWidgetHarness.super.onRenderBody(self, dc)
    if self:isPointerOverTarget() then
        self.hover_render_count = self.hover_render_count + 1
    end
end

---Records keyboard, text, pointer, button, and wheel host dispatch.
---@param keys table
---@return boolean
function OrdinaryWidgetHarness:onInput(keys)
    local string_code = keys._STRING
    if not string_code or string_code == 0 then
        for key in pairs(keys) do
            if type(key) == 'string' then
                string_code = tonumber(key:match('^STRING_A(%d%d%d)$'))
                if string_code then break end
            end
        end
    end
    if string_code and string_code ~= 0 then
        self.typed_text = self.typed_text .. string.char(string_code)
        return true
    end
    if keys.CUSTOM_A or keys.CUSTOM_B then
        self.custom_input_count = self.custom_input_count + 1
        return true
    end
    if self:isPointerOverTarget() then
        if keys._MOUSE_L then
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
        if keys.CONTEXT_SCROLL_DOWN then
            self.pointer_wheel_count = self.pointer_wheel_count + 1
            self:recordPhysicalEvent('wheel')
            return true
        end
    end
    return OrdinaryWidgetHarness.super.onInput(self, keys)
end

---Applies the entered value and adds a dynamically indexed descendant.
function OrdinaryWidgetHarness:submit()
    local editor = self.subviews.editor
    self.subviews.status:setText('saved:' .. editor.text)
    if not self.subviews.dynamic_result then
        self.subviews.nested_panel:addviews{
            widgets.Label{
                view_id='dynamic_result',
                frame={l=16, t=2, w=24},
                text='created:' .. editor.text,
            },
        }
        self:updateLayout()
    end
end

describe('ordinary widget component host', function()
    before_each(function()
        ds.wait_frames(1)
    end)

    after_each(function()
        pcall(ds.unmount)
    end)

    it('requires explicit unmount before mounting another widget', function()
        local first_instance = OrdinaryWidgetHarness{}
        local first = ds.mount(first_instance)

        assert.has_error(function()
            ds.mount(OrdinaryWidgetHarness)
        end, ('DwarfSpec mount rejected because mount %d is still current; ' ..
        'call ds.unmount() before creating another mount')
                :format(first.mount_id))
        command_conformance.assert_mounted_root(first, first_instance)
        command_conformance.assert_mounted_root(ds.root(), first_instance)
        ORDINARY_CAPABILITIES:assert_clean()

        ds.unmount()
        local second = ds.mount(OrdinaryWidgetHarness)

        assert.is_not.equals(first_instance, second:raw())
        ds.unmount()
    end)

    it('mounts an existing widget instance without mutating its class',
            function()
        local instance = OrdinaryWidgetHarness{}
        local original_on_render = rawget(OrdinaryWidgetHarness, 'onRender')
        local original_pause = df.global.pause_state
        local root = ds.mount(instance, {initial_pause=true})

        command_conformance.assert_mounted_root(root, instance)
        assert.is_true(df.global.pause_state)
        assert.equals(original_on_render,
            rawget(OrdinaryWidgetHarness, 'onRender'))
        assert.equals(128, instance.frame_parent_rect.width)
        assert.equals(64, instance.frame_parent_rect.height)
        ds.viewport(44, 12)
        assert.equals(44, instance.frame_parent_rect.width)
        assert.equals(12, instance.frame_parent_rect.height)
        ds.unmount()
        assert.equals(original_pause, df.global.pause_state)
        assert.equals(original_on_render,
            rawget(OrdinaryWidgetHarness, 'onRender'))
    end)

    it('renders from visible independently of active', function()
        local root = ds.mount(OrdinaryWidgetHarness)
        local widget = root:raw()
        local cases = {
            {visible=true, active=true, should_render=true},
            {visible=true, active=false, should_render=true},
            {visible=false, active=true, should_render=false},
            {visible=false, active=false, should_render=false},
        }

        for _, case in ipairs(cases) do
            widget.visible = case.visible
            widget.active = case.active
            local before = widget.render_count

            root:redraw()

            if case.should_render then
                assert.is_true(widget.render_count > before,
                    ('visible=%s active=%s should render'):format(
                        tostring(case.visible), tostring(case.active)))
            else
                assert.equals(before, widget.render_count,
                    ('visible=%s active=%s should not render'):format(
                        tostring(case.visible), tostring(case.active)))
            end
        end

        widget.visible = true
        widget.active = true
        ds.unmount()
    end)

    it('uses implicit mount context for nested interaction and inspection',
            function()
        local original_pause = df.global.pause_state
        local root = ds.mount(OrdinaryWidgetHarness, {
            viewport={width=60, height=20},
        })
        local editor = ds.get('nested_panel/editor')
        local tree = ds.capture_view_tree('ordinary-implicit-tree')

        assert.is_true(root:raw().saw_real_painter)
        assert.equals(60, root:raw().frame_parent_rect.width)
        assert.equals(20, root:raw().frame_parent_rect.height)
        assert.is_true(editor:inspect().visible)
        assert.is_true(editor:inspect().active)
        assert.is_truthy(editor:inspect().body)
        assert.equals('nested_panel', tree.children[1].view_id)

        editor:click():type('saved')
        assert.is_true(editor:inspect().focused)
        assert.equals('saved', editor:text())
        ds.get('nested_panel/submit'):click()
        assert.is_truthy(root:raw().subviews.nested_panel.subviews
            .dynamic_result)

        local dynamic = ds.get('nested_panel/dynamic_result')
        assert.is_true(dynamic:inspect().visible)
        assert.is_true(dynamic:inspect().active)
        assert.is_truthy(dynamic:inspect().body)

        ds.unmount()
        assert.equals(original_pause, df.global.pause_state)
        local available, stale_error = pcall(root.raw, root)
        assert.is_false(available)
        assert.matches('subject raw access rejected stale subject ' ..
            'control_path="<root>" from mount ', stale_error, 1, true)
        assert.matches('no current mount exists', stale_error,
            1, true)
    end)

    it('proves root inspection and top-level command route parity', function()
        local root = ds.mount(OrdinaryWidgetHarness, {
            viewport={width=60, height=20},
        })
        local component = root:raw()
        local target = ds.get('pointer_target')
        local editor = ds.get('nested_panel/editor')
        local state = ds.inspect()

        command_conformance.assert_mounted_root(root, component)
        assert.equals('ordinary_root', state.view_id)
        assert.is_true(state.visible)
        assert.is_true(state.active)
        assert.equals(component.frame_body.x1, state.body.x1)
        assert.equals(component.frame_body.y1, state.body.y1)
        assert.equals(component.frame_body.x2, state.body.x2)
        assert.equals(component.frame_body.y2, state.body.y2)
        assert.is_true(state.body.x2 >= state.body.x1)
        assert.is_true(state.body.y2 >= state.body.y1)

        local top_level_x, top_level_y =
            ds.move_pointer(target, 'bottom_right')
        local fluent_hover_renders = component.hover_render_count
        target:move_pointer('bottom_right')
        assert.same({top_level_x, top_level_y},
            {dfhack.screen.getMousePos()})
        assert.is_true(component.hover_render_count >
            fluent_hover_renders)

        local top_level_hover_renders = component.hover_render_count
        local hover_x, hover_y = ds.hover(target, 'top_left')
        assert.is_true(component.hover_render_count >
            top_level_hover_renders)
        local fluent_hover_before = component.hover_render_count
        target:hover('top_left')
        assert.same({hover_x, hover_y}, {dfhack.screen.getMousePos()})
        assert.is_true(component.hover_render_count >
            fluent_hover_before)

        local clicks = component.pointer_click_count
        ds.click(target)
        assert.equals(clicks + 1, component.pointer_click_count)
        clicks = component.pointer_click_count
        target:click()
        assert.equals(clicks + 1, component.pointer_click_count)

        local inputs = component.custom_input_count
        ds.input('CUSTOM_A', target)
        assert.equals(inputs + 1, component.custom_input_count)
        inputs = component.custom_input_count
        target:input('CUSTOM_B')
        assert.equals(inputs + 1, component.custom_input_count)

        editor:click()
        local typed_text = editor:text()
        ds.type('T', editor)
        assert.equals(typed_text .. 'T', editor:text())
        typed_text = editor:text()
        editor:type('F')
        assert.equals(typed_text .. 'F', editor:text())

        local focus_list = root:getFocusList()
        assert.is_true(#focus_list > 0 and #focus_list <= 8)
        for _, focus in ipairs(focus_list) do
            assert.is_true(type(focus) == 'string' and focus ~= '')
        end
        assert.matches('dwarfspec/component%-host$',
            focus_list[1])

        ds.unmount()
    end)

    it('routes physical mouse states over the rendered target', function()
        local root = ds.mount(OrdinaryWidgetHarness)
        local component = root:raw()
        local target = ds.get('pointer_target')
        local initial_pointer =
            command_conformance.pointer_snapshot()

        target:hover()
        assert.is_true(component:isPointerOverTarget())
        ds.mouseInput(ds.EMouseButton.LEFT)
        assert.equals(1, component.pointer_click_count)
        assert.equals('click', component.physical_events[1].kind)
        assert.is_true(component.physical_events[1].mouse_focus)
        assert.equals(1, component.physical_events[1].tracking_on)

        target:hover()
        assert.is_true(component:isPointerOverTarget())
        local down_count = component.pointer_down_count
        local down_event_start = #component.physical_events + 1
        ds.mouseInput(ds.EMouseButton.LEFT, ds.EInputState.DOWN)
        assert.is_true(component.pointer_down_count > down_count)
        local down
        for index=down_event_start,#component.physical_events do
            local candidate = component.physical_events[index]
            if candidate.mouse_lbut_down == 1 and
                    candidate.mouse_focus and candidate.tracking_on == 1 then
                down = candidate
                break
            end
        end
        assert.is_truthy(down,
            'DOWN dispatch must expose temporary button ownership')
        assert.equals('down', down.kind)
        assert.equals(1, down.mouse_lbut_down)
        assert.equals(0, down.mouse_lbut_lift)
        assert.is_true(down.mouse_focus)
        assert.equals(1, down.tracking_on)
        assert.equals(1, df.global.enabler.mouse_lbut_down)

        target:hover()
        assert.is_true(component:isPointerOverTarget())
        local up_count = component.pointer_up_count
        local up_event_start = #component.physical_events + 1
        ds.mouseInput(ds.EMouseButton.LEFT, ds.EInputState.UP)
        assert.is_true(component.pointer_up_count > up_count)
        local up
        for index=up_event_start,#component.physical_events do
            local candidate = component.physical_events[index]
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
        assert.equals(1, up.mouse_lbut_lift)
        assert.is_true(up.mouse_focus)
        assert.equals(1, up.tracking_on)
        assert.equals(0, df.global.enabler.mouse_lbut_down)
        assert.equals(0, df.global.enabler.mouse_lbut_lift)

        target:hover()
        assert.is_true(component:isPointerOverTarget())
        ds.mouseInput(ds.EMouseButton.SCROLL_DOWN)
        assert.equals(1, component.pointer_wheel_count,
            'ordinary host must explicitly handle the wheel dispatch')
        assert.equals('wheel',
            component.physical_events[#component.physical_events].kind)

        local discrete_wheel_count = component.pointer_wheel_count
        ds.mouseWheel({direction=ds.EMouseButton.SCROLL_DOWN, steps=2},
            target)
        assert.equals(discrete_wheel_count + 2, component.pointer_wheel_count,
            'discrete wheel dispatch must deliver every requested step')

        ds.unmount()
        command_conformance.assert_pointer_restored(
            initial_pointer, command_conformance.pointer_snapshot())
    end)

    it('distinguishes redraw timing and restores all owned state', function()
        local original_pause = df.global.pause_state
        local original_screen = dfhack.gui.getCurViewscreen(true)
        local original_width, original_height =
            dfhack.screen.getWindowSize()
        local instance = OrdinaryWidgetHarness{}
        local original_render = rawget(instance, 'onRender')
        local original_resize = rawget(instance, 'onResize')
        local run = ds.current_run()
        local root = ds.mount(instance, {
            viewport={width=58, height=19},
        })
        local host_screen = dfhack.gui.getCurViewscreen(true)

        assert.is_not.equals(original_screen, host_screen)
        ds.viewport(54, 18)
        assert.equals(54, instance.frame_parent_rect.width)
        assert.equals(18, instance.frame_parent_rect.height)

        command_conformance.assert_default_wait_redraw(function()
            return instance.render_count
        end, function()
            ds.redraw()
        end)
        command_conformance.assert_no_wait_redraw(function()
            return instance.render_count
        end, function()
            ds.redraw(nil, {wait=false})
        end, function(before)
            ds.await('ordinary no-wait redraw completes later', function()
                return instance.render_count > before
            end)
        end)

        local original_pointer =
            command_conformance.pointer_snapshot()
        ds.get('pointer_target'):hover()
        ds.mouseInput(ds.EMouseButton.LEFT, ds.EInputState.DOWN)
        ds.unmount()

        assert.equals(original_screen,
            dfhack.gui.getCurViewscreen(true))
        assert.equals(original_pause, df.global.pause_state)
        assert.same({original_width, original_height},
            {dfhack.screen.getWindowSize()})
        command_conformance.assert_pointer_restored(
            original_pointer, command_conformance.pointer_snapshot())
        assert.equals(original_render, rawget(instance, 'onRender'))
        assert.equals(original_resize, rawget(instance, 'onResize'))
        local cleanup = run.mount_cleanup_probe()
        assert.is_nil(cleanup.current_mount_id)
        assert.equals(0, cleanup.active_screen_count)
        assert.equals(0, cleanup.tracked_screen_count)
        assert.equals(0, cleanup.owned_screen_count)
        assert.equals(0, cleanup.subject_count)
        assert.is_false(cleanup.pointer_active)
        assert.is_false(cleanup.button_state_active)
        assert.is_false(cleanup.map_view_position_active)
        assert.is_false(cleanup.render_observer_active)
        assert.is_not.equals(host_screen,
            dfhack.gui.getCurViewscreen(true))
    end)
end)
