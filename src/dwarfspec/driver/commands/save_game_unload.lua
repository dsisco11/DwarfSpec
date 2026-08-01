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
    local scheduler_module = assert(dependencies.scheduler_module,
        'DwarfSpec save-game unload command requires a scheduler module')
    local scheduler = assert(dependencies.scheduler,
        'DwarfSpec save-game unload command requires a scheduler')
    local dfhack_api = assert(dependencies.dfhack,
        'DwarfSpec save-game unload command requires DFHack')
    local df_api = assert(dependencies.df,
        'DwarfSpec save-game unload command requires Dwarf Fortress types')
    local current_viewscreen = assert(dependencies.current_viewscreen,
        'DwarfSpec save-game unload command requires viewscreen access')
    local get_window_size = assert(dependencies.get_window_size,
        'DwarfSpec save-game unload command requires window geometry')
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
        local gui = dependencies.gui or require('gui')
        return gui.simulateInput(screen, key)
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
        return scheduler_module.wait_until(scheduler, description, query, {
            timeout_ms=wait_settings.timeout_ms,
            frame_budget=wait_settings.frame_budget,
        })
    end

    ---Returns the current native focus string for diagnostics.
    ---@return string
    local function current_native_focus()
        local focus = dfhack_api.gui.getCurFocus()
        return type(focus) == 'table' and focus[1] or tostring(focus)
    end

    return workflow.new({
        is_world_loaded=function() return dfhack_api.isWorldLoaded() end,
        read_world_folder=function()
            return dfhack_api.world.ReadWorldFolder()
        end,
        get_options=function()
            return df_api.global.game.main_interface.options
        end,
        get_screen=current_viewscreen,
        main_menu_option_type=df_api.main_menu_option_type,
        open_options=function(screen)
            simulate_native_input(screen, 'OPTIONS')
        end,
        get_window_size=get_window_size,
        move_pointer=move_native_pointer,
        click_left=click_native,
        capture_input_state=function()
            return pointer_adapter.begin_transient(pointer)
        end,
        wait_until=wait_for_save_game_state,
        wait_frames=function(count)
            return scheduler_module.wait_frames(scheduler, count)
        end,
        get_focus=current_native_focus,
        get_viewscreen=function()
            local screen = current_viewscreen()
            return screen and screen._type
        end,
    })
end

return M
