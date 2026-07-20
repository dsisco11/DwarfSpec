-- Test-owned live screen used to exercise generic automation interactions.

local gui = require('gui')
local widgets = require('gui.widgets')

---@class tests.AutomationInteractionScreen: gui.ZScreen
local AutomationInteractionScreen = defclass(nil, gui.ZScreen)
AutomationInteractionScreen.ATTRS{
    initial_pause=false,
    pass_mouse_clicks=false,
}

---Builds the deterministic fixture widget tree.
---@param options table|nil
function AutomationInteractionScreen:init(options)
    options = options or {}
    self.render_generation = 0
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
    self.root = widgets.Panel{
        view_id='fixture_root',
        frame={l=options.left or 2, t=options.top or 2, w=32, h=8},
        subviews={self.target, self.input, self.clicks},
    }
    self:addviews{self.root}
end

---Records a real render and updates fixture-only hover text.
function AutomationInteractionScreen:onRender()
    AutomationInteractionScreen.super.onRender(self)
    self.render_generation = self.render_generation + 1
    local x, y = dfhack.screen.getMousePos()
    local body = self.target.frame_body
    if x and y and body and body:inClipGlobalXY(x, y) then
        local local_x, local_y = body:localXY(x, y)
        self.target.tooltip = ('Automation hover %d,%d'):format(
            local_x, local_y)
    end
end

---Handles synthetic fixture input through DFHack's native input path.
---@param keys table
---@return boolean
function AutomationInteractionScreen:onInput(keys)
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
    return AutomationInteractionScreen.super.onInput(self, keys)
end

local M = {}

---Creates one interaction fixture screen.
---@param options table|nil
---@return table
function M.new(options)
    return AutomationInteractionScreen(options)
end

return M
