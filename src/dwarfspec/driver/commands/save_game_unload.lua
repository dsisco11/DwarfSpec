-- Native DFHack binding for the save-game unload workflow.

local M = {}

---Creates the live DFHack save-game unloader.
---@param dependencies table
---@return table
function M.new(dependencies)
    assert(type(dependencies) == 'table',
        'DwarfSpec save-game unload command requires dependencies')
    local workflow = assert(dependencies.workflow,
        'DwarfSpec save-game unload command requires its workflow')
    local scheduling = assert(dependencies.scheduling,
        'DwarfSpec save-game unload command requires scheduling capabilities')
    assert(type(scheduling.wait_until) == 'function' and
            type(scheduling.wait_frames) == 'function',
        'DwarfSpec save-game unload command requires wait capabilities')
    local native_game = assert(dependencies.native_game,
        'DwarfSpec save-game unload command requires native-game capabilities')
    for _, name in ipairs({
            'is_world_loaded', 'read_world_folder', 'get_focus',
            'current_viewscreen', 'get_window_size', 'simulate_input',
            'get_options'}) do
        assert(type(native_game[name]) == 'function',
            'DwarfSpec save-game unload command requires native_game.' ..
                name .. '()')
    end
    assert(native_game.main_menu_option_type ~= nil,
        'DwarfSpec save-game unload command requires ' ..
            'native_game.main_menu_option_type')
    local pointer_adapter = assert(dependencies.pointer_adapter,
        'DwarfSpec save-game unload command requires a pointer adapter')
    local pointer = assert(dependencies.pointer,
        'DwarfSpec save-game unload command requires a pointer')
    local wait_settings = dependencies.wait_settings or {}

    ---Dispatches one built-in DFHack input key to a native viewscreen.
    ---@param screen any
    ---@param key string
    local function simulate_native_input(screen, key)
        assert(screen ~= nil,
            'DwarfSpec save-game input requires a native viewscreen')
        return native_game.simulate_input(screen, key)
    end

    ---Moves DFHack's virtual native pointer to one UI-grid cell.
    ---@param x integer
    ---@param y integer
    local function move_native_pointer(x, y)
        pointer_adapter.set_grid(pointer, x, y)
    end

    ---Clicks one native viewscreen through the shared pointer lifecycle.
    ---@param screen any
    local function click_native(screen)
        pointer_adapter.with_mouse_focus(pointer, function()
            pointer_adapter.sync(pointer)
            simulate_native_input(screen, '_MOUSE_L')
        end)
    end

    ---Waits for a save-game transition using the run's raw-frame scheduler.
    ---@param description string
    ---@param query function
    ---@return any
    local function wait_for_save_game_state(description, query)
        return scheduling.wait_until(description, query, {
            timeout_ms=wait_settings.timeout_ms,
            frame_budget=wait_settings.frame_budget,
        })
    end

    ---Returns the current native focus string for diagnostics.
    ---@return string
    local function current_native_focus()
        local focus = native_game.get_focus()
        return type(focus) == 'table' and focus[1] or tostring(focus)
    end

    return workflow.new({
        is_world_loaded=native_game.is_world_loaded,
        read_world_folder=native_game.read_world_folder,
        get_options=native_game.get_options,
        get_screen=native_game.current_viewscreen,
        main_menu_option_type=native_game.main_menu_option_type,
        open_options=function(screen)
            simulate_native_input(screen, 'OPTIONS')
        end,
        get_window_size=native_game.get_window_size,
        move_pointer=move_native_pointer,
        click_left=click_native,
        capture_input_state=function()
            return pointer_adapter.begin_transient(pointer)
        end,
        wait_until=wait_for_save_game_state,
        wait_frames=function(count)
            return scheduling.wait_frames(count)
        end,
        get_focus=current_native_focus,
        get_viewscreen=function()
            local screen = native_game.current_viewscreen()
            return screen and screen._type
        end,
    })
end

return M
