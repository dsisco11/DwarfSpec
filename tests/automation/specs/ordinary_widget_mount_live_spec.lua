-- Product-independent live proof for ordinary widget component mounting.

local widgets = require('gui.widgets')

---@class tests.OrdinaryWidgetHarness: widgets.Panel
local OrdinaryWidgetHarness = defclass(nil, widgets.Panel)
OrdinaryWidgetHarness.ATTRS{
    frame={w=50, h=8},
}

---Creates nested interactive content using only normal DFHack widgets.
function OrdinaryWidgetHarness:init()
    self.saw_real_painter = false
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
    }
end

---Records that normal rendering supplied a live painter to the component.
---@param dc gui.Painter
function OrdinaryWidgetHarness:onRenderBody(dc)
    self.saw_real_painter = type(dc) == 'table' and
        type(dc.seek) == 'function'
    OrdinaryWidgetHarness.super.onRenderBody(self, dc)
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
    it('mounts an existing widget instance without mutating its class',
            function()
        local instance = OrdinaryWidgetHarness{}
        local original_on_render = rawget(OrdinaryWidgetHarness, 'onRender')
        local original_pause = df.global.pause_state
        local root = ds.mount(instance, {initial_pause=false})

        assert.equals(instance, root:raw())
        assert.equals(original_pause, df.global.pause_state)
        assert.equals(original_on_render,
            rawget(OrdinaryWidgetHarness, 'onRender'))
        ds.resize(44, 12)
        assert.equals(44, instance.frame_parent_rect.width)
        assert.equals(12, instance.frame_parent_rect.height)
        ds.unmount()
        assert.equals(original_pause, df.global.pause_state)
        assert.equals(original_on_render,
            rawget(OrdinaryWidgetHarness, 'onRender'))
    end)

    it('uses implicit mount context for nested interaction and inspection',
            function()
        local original_pause = df.global.pause_state
        local root = ds.mount(OrdinaryWidgetHarness, {
            viewport={width=60, height=20},
        })
        local editor = ds.get('editor')
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
        ds.get('submit'):click()
        assert.is_truthy(root:raw().subviews.nested_panel.subviews
            .dynamic_result)

        local dynamic = ds.get('dynamic_result')
        assert.is_true(dynamic:inspect().visible)
        assert.is_true(dynamic:inspect().active)
        assert.is_truthy(dynamic:inspect().body)

        ds.unmount()
        assert.equals(original_pause, df.global.pause_state)
        local available, stale_error = pcall(root.raw, root)
        assert.is_false(available)
        assert.matches('subject raw access rejected stale subject ' ..
            'view_id="<root>" from mount ', stale_error, 1, true)
        assert.matches('no component is currently mounted', stale_error,
            1, true)
    end)
end)
