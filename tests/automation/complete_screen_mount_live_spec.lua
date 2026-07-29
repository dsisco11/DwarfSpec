-- Product-independent live proof for complete ZScreen component mounting.

local gui = require('gui')
local widgets = require('gui.widgets')
local command_conformance = require(
    'tests.automation.support.command_conformance')

local COMPLETE_SCREEN_CAPABILITIES = command_conformance.new{
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

---@class tests.CompleteScreenBacking: gui.ZScreen
local CompleteScreenBacking = defclass(nil, gui.ZScreen)
CompleteScreenBacking.ATTRS{
    focus_path='dwarfspec/complete-screen-backing',
    initial_pause=false,
}

---Records input forwarded by a mounted child screen.
---@param keys table
---@return boolean
function CompleteScreenBacking:onInput(keys)
    if keys.D_PAUSE then
        self.forwarded_pause = (self.forwarded_pause or 0) + 1
        return true
    end
    if keys.CONTEXT_SCROLL_DOWN then
        self.forwarded_wheel = (self.forwarded_wheel or 0) + 1
    end
    return CompleteScreenBacking.super.onInput(self, keys)
end

---@class tests.CompleteScreenModal: gui.FramedScreen
local CompleteScreenModal = defclass(nil, gui.FramedScreen)
CompleteScreenModal.ATTRS{
    frame_title='Mounted child',
    frame_width=28,
    frame_height=7,
    owner=DEFAULT_NIL,
}

---Creates content that must remain outside the implicit component root.
function CompleteScreenModal:init()
    self:addviews{
        widgets.Label{
            view_id='modal_only',
            frame={l=1, t=1},
            text='modal child',
        },
    }
end

---Handles one modal input and closes the child screen.
---@param keys table
---@return boolean
function CompleteScreenModal:onInput(keys)
    if keys.CUSTOM_A then
        self.owner.modal_result = 'handled'
        self:dismiss()
        return true
    end
    return CompleteScreenModal.super.onInput(self, keys)
end

---@class tests.CompleteScreenHarness: gui.ZScreen
local CompleteScreenHarness = defclass(nil, gui.ZScreen)
CompleteScreenHarness.ATTRS{
    focus_path='dwarfspec/complete-screen-harness',
    pass_pause=true,
}

---@class tests.UnpausedCompleteScreenHarness: tests.CompleteScreenHarness
local UnpausedCompleteScreenHarness = defclass(
    nil, CompleteScreenHarness)
UnpausedCompleteScreenHarness.ATTRS{
    initial_pause=false,
}

---Creates ordinary interactive descendants without test render hooks.
function CompleteScreenHarness:init()
    self.render_count = 0
    self.pointer_click_count = 0
    self.pointer_down_count = 0
    self.pointer_up_count = 0
    self.wheel_count = 0
    self.physical_events = {}
    self:addviews{
        widgets.Panel{
            view_id='content',
            frame={l=0, t=0, r=0, b=0},
            subviews={
                widgets.EditField{
                    view_id='editor',
                    frame={l=2, t=2, w=24},
                    text='',
                },
                widgets.HotkeyLabel{
                    view_id='submit',
                    frame={l=2, t=4, w=14},
                    label='Submit',
                    on_activate=self:callback('submit'),
                },
                widgets.Label{
                    view_id='status',
                    frame={l=2, t=6, w=30},
                    text='pending',
                },
                widgets.HotkeyLabel{
                    view_id='open_modal',
                    frame={l=2, t=8, w=18},
                    label='Open modal',
                    on_activate=self:callback('open_modal'),
                },
                widgets.Label{
                    view_id='pointer_target',
                    frame={l=2, t=10, w=24, h=2},
                    text='Rendered pointer target',
                },
            },
        },
    }
end

---Returns whether the live pointer lies within the rendered pointer target.
---@return boolean
function CompleteScreenHarness:isPointerOverTarget()
    local x, y = dfhack.screen.getMousePos()
    local body = self.subviews.pointer_target.frame_body
    return x ~= nil and y ~= nil and body ~= nil and
        body:inClipGlobalXY(x, y)
end

---Records one physical input with its temporary DF pointer ownership state.
---@param kind string
function CompleteScreenHarness:recordPhysicalEvent(kind)
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

---Records physical input before allowing unconsumed events to reach backing screens.
---@param keys table
---@return boolean
function CompleteScreenHarness:onInput(keys)
    if keys._MOUSE_L and self:isPointerOverTarget() then
        self.pointer_click_count = self.pointer_click_count + 1
        self:recordPhysicalEvent('click')
        return true
    end
    if keys._MOUSE_L_DOWN and self:isPointerOverTarget() then
        self.pointer_down_count = self.pointer_down_count + 1
        self:recordPhysicalEvent('down')
        return true
    end
    if df.global.enabler.mouse_lbut_lift == 1 and self:isPointerOverTarget() then
        self.pointer_up_count = self.pointer_up_count + 1
        self:recordPhysicalEvent('up')
        return true
    end
    if keys.CONTEXT_SCROLL_DOWN then
        self.wheel_count = self.wheel_count + 1
        self:recordPhysicalEvent('wheel')
        self:sendInputToParent(keys)
        return true
    end
    return CompleteScreenHarness.super.onInput(self, keys)
end

---Records each complete-screen render before delegating to the standard painter.
---@param dc gui.Painter
function CompleteScreenHarness:onRender(dc)
    self.render_count = self.render_count + 1
    return CompleteScreenHarness.super.onRender(self, dc)
end

---Copies editor text into the visible status label.
function CompleteScreenHarness:submit()
    self.subviews.status:setText('saved:' .. self.subviews.editor.text)
end

---Shows a native modal child above this mounted root screen.
function CompleteScreenHarness:open_modal()
    self.modal = CompleteScreenModal{owner=self}
    self.modal:show(self._native)
end

describe('complete screen component mount', function()
    local backing
    local original_pause

    before_each(function()
        original_pause = df.global.pause_state
        df.global.pause_state = false
        backing = CompleteScreenBacking{}
        backing:show()
        ds.await('complete-screen backing becomes current', function()
            return backing:isActive() and
                dfhack.gui.getCurViewscreen(true) == backing._native
        end)
    end)

    after_each(function()
        pcall(ds.unmount)
        if backing then pcall(backing.dismiss, backing) end
        df.global.pause_state = original_pause
    end)

    it('mounts a class directly with fluent descendants and native behavior',
            function()
        local pointer_before = command_conformance.pointer_snapshot()
        local root = ds.mount(CompleteScreenHarness, {
            backing_viewscreen=backing._native,
            initial_pause=true,
            viewport={width=52, height=16},
        })
        local screen = root:raw()

        assert.equals(CompleteScreenHarness, getmetatable(screen))
        command_conformance.assert_mounted_root(root, screen)
        command_conformance.assert_mounted_root(ds.root(), screen)
        COMPLETE_SCREEN_CAPABILITIES:assert_clean()
        assert.equals(screen._native,
            dfhack.gui.getCurViewscreen(true))
        assert.is_true(df.global.pause_state)
        assert.equals(52, screen.frame_parent_rect.width)
        assert.equals(16, screen.frame_parent_rect.height)
        assert.is_true(screen.render_count > 0)
        assert.is_function(CompleteScreenHarness.onRender)

        ds.get('content/editor'):click():type('value')
        ds.get('content/submit'):click()
        assert.equals('saved:value', ds.get('content/status'):text())
        ds.viewport(90, 30)
        assert.equals(90, screen.frame_parent_rect.width)
        assert.equals(30, screen.frame_parent_rect.height)

        root:input('D_PAUSE')
        assert.equals(1, backing.forwarded_pause)
        ds.get('content/open_modal'):click()
        assert.is_true(screen.modal:isActive())
        assert.equals(screen, ds.root():raw())
        local selected, selection_error = pcall(ds.get, 'modal_only')
        assert.is_false(selected)
        assert.matches('selected_control_path="modal_only"', selection_error,
            1, true)
        assert.matches(('control_path="modal_only" mount=%d missing ' ..
            'segment="modal_only" after="<root>"'):format(root.mount_id),
            selection_error, 1, true)
        assert.equals(screen.modal._native, dfhack.gui.getCurViewscreen(true),
            'a failed lookup must leave the active complete-screen child intact')
        assert.equals(screen, ds.root():raw(),
            'a failed lookup must retain the mounted complete-screen root')
        root:input('CUSTOM_A')
        assert.equals('handled', screen.modal_result)
        assert.is_false(screen.modal:isActive())
        assert.equals(screen, ds.root():raw())

        local target = ds.get('content/pointer_target')
        target:hover('center')
        local hover_x, hover_y = dfhack.screen.getMousePos()
        assert.is_true(screen:isPointerOverTarget())
        assert.is_true(target:raw().frame_body:inClipGlobalXY(hover_x, hover_y))

        ds.mouseInput(ds.EMouseButton.LEFT)
        assert.equals(1, screen.pointer_click_count)
        assert.equals('click', screen.physical_events[1].kind)
        assert.is_true(screen.physical_events[1].mouse_focus)

        target:hover('center')
        ds.mouseInput(ds.EMouseButton.LEFT, ds.EInputState.DOWN)
        assert.is_true(screen.pointer_down_count > 0)
        local down = screen.physical_events[#screen.physical_events]
        assert.equals('down', down.kind)
        assert.equals(1, down.mouse_lbut_down)
        assert.is_true(down.mouse_focus)

        target:hover('center')
        ds.mouseInput(ds.EMouseButton.LEFT, ds.EInputState.UP)
        assert.is_true(screen.pointer_up_count > 0)
        local up = screen.physical_events[#screen.physical_events]
        assert.equals('up', up.kind)
        assert.equals(1, up.mouse_lbut_lift)
        assert.is_true(up.mouse_focus)

        target:hover('center')
        local backing_wheels = backing.forwarded_wheel or 0
        ds.mouseInput(ds.EMouseButton.SCROLL_DOWN)
        assert.equals(1, screen.wheel_count)
        assert.equals(backing_wheels + 1, backing.forwarded_wheel,
            'unconsumed complete-screen wheel input must reach the backing screen')
        assert.equals('wheel', screen.physical_events[#screen.physical_events].kind)

        assert.same({'dfhack/lua/dwarfspec/complete-screen-harness'},
            root:getFocusList())
        assert.same(dfhack.gui.getFocusStrings(screen._native),
            root:getFocusList())

        command_conformance.assert_default_wait_redraw(function()
            return screen.render_count
        end, function()
            root:redraw()
        end)

        ds.unmount()
        assert.is_false(screen:isActive())
        assert.equals(backing._native, dfhack.gui.getCurViewscreen(true))
        assert.is_false(df.global.pause_state)
        command_conformance.assert_pointer_restored(
            pointer_before, command_conformance.pointer_snapshot())
        assert.is_nil(rawget(screen, 'onResize'))
    end)

    it('mounts an existing instance without replacing native methods',
            function()
        local screen = UnpausedCompleteScreenHarness{}
        local original_input = screen.onInput
        local original_dismiss = screen.dismiss
        local original_render = rawget(screen, 'onRender')
        local original_resize = rawget(screen, 'onResize')
        local root = ds.mount(screen, {
            backing_viewscreen=backing._native,
        })

        command_conformance.assert_mounted_root(root, screen)
        assert.is_false(df.global.pause_state)
        assert.equals(128, screen.frame_parent_rect.width)
        assert.equals(64, screen.frame_parent_rect.height)
        assert.equals(original_input, screen.onInput)
        assert.equals(original_dismiss, screen.dismiss)
        root:input('D_PAUSE')
        assert.equals(1, backing.forwarded_pause)
        screen:dismiss()
        assert.is_false(screen:isActive())
        ds.unmount()
        assert.equals(original_render, rawget(screen, 'onRender'))
        assert.equals(original_resize, rawget(screen, 'onResize'))
        assert.equals(original_input, screen.onInput)
        assert.equals(original_dismiss, screen.dismiss)
    end)
end)
