-- Product-independent live proof for complete ZScreen component mounting.

local gui = require('gui')
local widgets = require('gui.widgets')

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
            },
        },
    }
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
    end)

    after_each(function()
        pcall(ds.unmount)
        if backing and backing:isActive() then backing:dismiss() end
        df.global.pause_state = original_pause
    end)

    it('mounts a class directly with fluent descendants and native behavior',
            function()
        local root = ds.mount(CompleteScreenHarness, {
            backing_viewscreen=backing._native,
            initial_pause=true,
            viewport={width=52, height=16},
        })
        local screen = root:raw()

        assert.equals(CompleteScreenHarness, getmetatable(screen))
        assert.equals(screen, ds.root():raw())
        assert.equals(screen._native,
            dfhack.gui.getCurViewscreen(true))
        assert.is_true(df.global.pause_state)
        assert.equals(52, screen.frame_parent_rect.width)
        assert.equals(16, screen.frame_parent_rect.height)
        assert.is_nil(screen.render_generation)
        assert.is_nil(rawget(CompleteScreenHarness, 'onRender'))

        ds.get('editor'):click():type('value')
        ds.get('submit'):click()
        assert.equals('saved:value', ds.get('status'):text())
        ds.viewport(90, 30)
        assert.equals(90, screen.frame_parent_rect.width)
        assert.equals(30, screen.frame_parent_rect.height)

        root:input('D_PAUSE')
        assert.equals(1, backing.forwarded_pause)
        ds.get('open_modal'):click()
        assert.is_true(screen.modal:isActive())
        assert.equals(screen, ds.root():raw())
        local selected, selection_error = pcall(ds.get, 'modal_only')
        assert.is_false(selected)
        assert.matches('selected_view_id="modal_only"', selection_error,
            1, true)
        assert.matches('view_id="modal_only" mount=1 was not found',
            selection_error, 1, true)
        root:input('CUSTOM_A')
        assert.equals('handled', screen.modal_result)
        assert.is_false(screen.modal:isActive())
        assert.equals(screen, ds.root():raw())

        ds.unmount()
        assert.is_false(screen:isActive())
        assert.is_false(df.global.pause_state)
        assert.is_nil(rawget(screen, 'onRender'))
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

        assert.equals(screen, root:raw())
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
