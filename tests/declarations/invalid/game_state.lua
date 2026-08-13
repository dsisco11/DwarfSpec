---Supplies intentionally invalid game-state setter declarations.
---@return fun()
local function invalid_declaration_fixture()
    return function()
        ds.setGamePaused('yes')
        ds.setGameSpeed(false)
        ds.setTurboSpeed(1)
        ---@type string
        local paused = ds.setGamePaused(true)
        ---@type boolean
        local tps = ds.setGameSpeed(100)
        ---@type integer
        local turbo = ds.setTurboSpeed(false)
        assert(paused and tps and turbo)
    end
end

return invalid_declaration_fixture
