-- Co-located test-owned screen for the minimal consumer proof.

local gui = require('gui')

---@class tests.MinimalCoverScreen: gui.ZScreen
local MinimalCoverScreen = defclass(nil, gui.ZScreen)
MinimalCoverScreen.ATTRS{
    initial_pause=false,
    pass_mouse_clicks=true,
}

---Initializes the live render counter.
function MinimalCoverScreen:init()
    self.render_generation = 0
end

---Records each real render of the fixture screen.
function MinimalCoverScreen:onRender()
    MinimalCoverScreen.super.onRender(self)
    self.render_generation = self.render_generation + 1
end

local M = {}

---Creates one test-owned covering screen.
---@return table
function M.new()
    return MinimalCoverScreen{}
end

return M
