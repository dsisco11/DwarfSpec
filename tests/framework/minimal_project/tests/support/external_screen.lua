-- Importable fixture intentionally located outside the recommended convention.

local gui = require('gui')

---@class tests.MinimalExternalScreen: gui.ZScreen
local MinimalExternalScreen = defclass(nil, gui.ZScreen)
MinimalExternalScreen.ATTRS{
    initial_pause=false,
    pass_mouse_clicks=true,
}

---Initializes the live render counter.
function MinimalExternalScreen:init()
    self.render_generation = 0
end

---Records each real render of the fixture screen.
function MinimalExternalScreen:onRender()
    MinimalExternalScreen.super.onRender(self)
    self.render_generation = self.render_generation + 1
end

local M = {}

---Creates one external-location fixture screen.
---@return table
function M.new()
    return MinimalExternalScreen{}
end

return M
