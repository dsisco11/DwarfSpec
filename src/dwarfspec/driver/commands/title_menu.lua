-- Shared native title-menu inspection and navigation.

local M = {}

---Returns the normalized state of the native title screen.
---@param native_game table
---@return table|nil
function M.read(native_game)
    assert(type(native_game) == 'table',
        'DwarfSpec title-menu inspection requires native-game capabilities')
    assert(type(native_game.current_viewscreen) == 'function',
        'DwarfSpec title-menu inspection requires ' ..
            'native_game.current_viewscreen()')
    assert(native_game.title_screen_type ~= nil,
        'DwarfSpec title-menu inspection requires ' ..
            'native_game.title_screen_type')
    assert(native_game.title_mode_type ~= nil,
        'DwarfSpec title-menu inspection requires native_game.title_mode_type')

    local screen = native_game.current_viewscreen()
    if not native_game.title_screen_type:is_instance(screen) then return nil end
    local modes = native_game.title_mode_type
    local mode
    if screen.mode == modes.MAIN_MENU then
        mode = 'main'
    elseif screen.mode == modes.CONTINUE_ACTIVE_WORLD then
        mode = 'world-list'
    elseif screen.mode == modes.CONTINUE_ACTIVE then
        mode = 'save-list'
    else
        mode = tostring(screen.mode)
    end
    return {mode=mode, screen=screen}
end

---Navigates a native title submenu back to the main menu.
---@param native_game table
---@param simulate_input function
---@param wait_until function
---@return table
function M.reach_main_menu(native_game, simulate_input, wait_until)
    assert(type(simulate_input) == 'function',
        'DwarfSpec title-menu navigation requires simulated input')
    assert(type(wait_until) == 'function',
        'DwarfSpec title-menu navigation requires waiting')
    for _ = 1, 3 do
        local state = M.read(native_game)
        assert(state, 'DwarfSpec title-menu navigation requires the title screen')
        if state.mode == 'main' then return state end
        local previous_mode = state.mode
        simulate_input(state.screen, 'LEAVESCREEN')
        local current = wait_until('return to title main menu', function()
            local current = M.read(native_game)
            return current and current.mode ~= previous_mode and current or nil
        end)
        if current.mode == 'main' then return current end
    end
    error('DwarfSpec could not reach the title main menu', 2)
end

return M
