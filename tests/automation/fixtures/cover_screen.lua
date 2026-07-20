-- Test-owned screen that temporarily covers the tooltip service.

local gui = require('gui')

---@class tests.AutomationCoverScreen: gui.ZScreen
local AutomationCoverScreen = defclass(nil, gui.ZScreen)
AutomationCoverScreen.ATTRS{
    initial_pause=false,
    pass_mouse_clicks=true,
}

---Initializes the live-render counter used by the automation driver.
function AutomationCoverScreen:init()
    self.render_generation = 0
end

---Records each real render of the covering screen.
function AutomationCoverScreen:onRender()
    AutomationCoverScreen.super.onRender(self)
    self.render_generation = self.render_generation + 1
end

local M = {}

---Creates one test-owned covering screen.
---@return table
function M.new()
    return AutomationCoverScreen{}
end

return M
