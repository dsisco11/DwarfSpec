-- Live contracts for mounted-component interaction, inspection, and capture.

local widgets = require('gui.widgets')

---@class tests.AutomationInteractionWidget: widgets.Panel
local AutomationInteractionWidget = defclass(nil, widgets.Panel)
AutomationInteractionWidget.ATTRS{
    view_id='interaction_root',
    frame={w=32, h=8},
}

---Builds the deterministic mounted widget tree.
function AutomationInteractionWidget:init()
    self.click_count = 0
    self.typed_text = ''
    self.last_key = nil
    self.target = widgets.Label{
        view_id='tooltip_target',
        frame={l=1, t=1, w=20, h=1},
        text='Automation target',
        tooltip='Automation tooltip',
    }
    self.input = widgets.Label{
        view_id='input_echo',
        frame={l=1, t=3, w=28, h=1},
        text='Typed: ',
    }
    self.clicks = widgets.Label{
        view_id='click_echo',
        frame={l=1, t=5, w=28, h=1},
        text='Clicks: 0',
    }
    self:addviews{self.target, self.input, self.clicks}
end

---Updates test tooltip text before ordinary component rendering.
---@param dc gui.Painter
function AutomationInteractionWidget:render(dc)
    local x, y = dfhack.screen.getMousePos()
    local body = self.target.frame_body
    if x and y and body and body:inClipGlobalXY(x, y) then
        local local_x, local_y = body:localXY(x, y)
        self.target.tooltip = ('Automation hover %d,%d'):format(
            local_x, local_y)
    end
    AutomationInteractionWidget.super.render(self, dc)
end

---Handles synthetic input through ordinary mounted-widget dispatch.
---@param keys table
---@return boolean
function AutomationInteractionWidget:onInput(keys)
    if keys._STRING and keys._STRING ~= 0 then
        self.typed_text = self.typed_text .. string.char(keys._STRING)
        self.input:setText('Typed: ' .. self.typed_text)
        return true
    end
    if keys._MOUSE_L then
        local x, y = dfhack.screen.getMousePos()
        if self.target.frame_body:inClipGlobalXY(x, y) then
            self.click_count = self.click_count + 1
            self.clicks:setText('Clicks: ' .. self.click_count)
            return true
        end
    end
    for key in pairs(keys) do
        if type(key) == 'string' and key:match('^CUSTOM_') then
            self.last_key = key
            return true
        end
    end
    return AutomationInteractionWidget.super.onInput(self, keys)
end

describe('automation live interactions', function()
    it('mounts, selects, inspects, interacts, captures, and unmounts',
            function()
        local initial_pause_state = df.global.pause_state
        local initial_pointer_function = dfhack.screen.getMousePos
        local root = ds.mount(AutomationInteractionWidget)
        local target = ds.get('tooltip_target')
        local input = ds.get('input_echo')
        local component = root:raw()

        local inspection = target:inspect()
        local tree = ds.capture_view_tree('interaction-tree')
        assert.equals('tooltip_target', inspection.view_id)
        assert.is_true(inspection.visible)
        assert.is_truthy(inspection.body)
        assert.equals('interaction_root', tree.view_id)
        assert.equals(0, component.click_count)

        target:move_pointer()
        assert.matches('^Automation hover %d+,%d+$', target:raw().tooltip)
        target:click()
        assert.equals(1, component.click_count)
        root:type('Hi')
        assert.equals('Hi', component.typed_text)
        assert.equals('Typed: Hi', input:text())
        root:input('CUSTOM_A')
        assert.equals('CUSTOM_A', component.last_key)

        local capture = ds.capture_screen('interaction-cells', {
            max_width=8,
            max_height=4,
        })
        assert.equals(8, capture.width)
        assert.equals(4, capture.height)
        assert.equals(4, #capture.cells)

        ds.unmount()
        assert.equals(initial_pointer_function, dfhack.screen.getMousePos)
        assert.equals(initial_pause_state, df.global.pause_state)
    end)
end)
