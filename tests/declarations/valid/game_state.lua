---Exercises every supported game-state setter declaration.
---@return fun()
local function declaration_fixture()
    return function()
        ---@type boolean
        local paused = ds.setGamePaused(true)
        ---@type integer
        local tps = ds.setGameSpeed(100)
        ---@type boolean
        local turbo = ds.setTurboSpeed(false)
        ds.setGamePaused(paused, {timeout_ms=1000})
        ds.setGameSpeed(tps, {timeout_ms=1000})
        ds.setTurboSpeed(turbo, {timeout_ms=1000})
    end
end

return declaration_fixture
