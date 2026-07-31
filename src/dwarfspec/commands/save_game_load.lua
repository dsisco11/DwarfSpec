-- Native DFHack binding for the save-game load workflow.

local M = {}

---Returns a stable identity for one native save header's world.
---@param header any
---@return string
local function save_world_identity(header)
    local world_header = assert(header and header.world_header,
        'DwarfSpec native save header has no world header')
    return ('%s:%s'):format(tostring(world_header.id1),
        tostring(world_header.id2))
end

---Normalizes one native save-header vector for the loading workflow.
---@param headers any
---@return table
local function normalize_save_headers(headers)
    local normalized = {}
    for _, header in ipairs(headers or {}) do
        normalized[#normalized + 1] = {
            directory_name=header.filename_noext,
            world_id=save_world_identity(header),
        }
    end
    return normalized
end

---Creates the live DFHack save-game loader.
---@param dependencies table
---@return table
function M.new(dependencies)
    assert(type(dependencies) == 'table',
        'DwarfSpec save-game load command requires dependencies')
    local workflow = assert(dependencies.workflow,
        'DwarfSpec save-game load command requires its workflow')
    local scheduler_module = assert(dependencies.scheduler_module,
        'DwarfSpec save-game load command requires a scheduler module')
    local scheduler = assert(dependencies.scheduler,
        'DwarfSpec save-game load command requires a scheduler')
    local dfhack_api = assert(dependencies.dfhack,
        'DwarfSpec save-game load command requires DFHack')
    local df_api = assert(dependencies.df,
        'DwarfSpec save-game load command requires Dwarf Fortress types')
    local current_viewscreen = assert(dependencies.current_viewscreen,
        'DwarfSpec save-game load command requires viewscreen access')
    local get_window_size = assert(dependencies.get_window_size,
        'DwarfSpec save-game load command requires window geometry')
    local pointer_adapter = assert(dependencies.pointer_adapter,
        'DwarfSpec save-game load command requires a pointer adapter')
    local pointer = assert(dependencies.pointer,
        'DwarfSpec save-game load command requires a pointer')
    local EEvent = assert(dependencies.events,
        'DwarfSpec save-game load command requires public event identifiers')
    local await_event = assert(dependencies.await_event,
        'DwarfSpec save-game load command requires event awaiting')
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

    ---Returns the current normalized native title state.
    ---@return table|nil
    local function get_native_title_state()
        local screen = current_viewscreen()
        local title_type = df_api.viewscreen_titlest
        if not title_type or not title_type:is_instance(screen) then return nil end
        local modes = assert(df_api.title_mode_type,
            'DwarfSpec save-game load requires df.title_mode_type')
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
        return {
            mode=mode,
            screen=screen,
            all_saves=normalize_save_headers(screen.savegame_header),
            world_saves=normalize_save_headers(screen.savegame_header_world),
            game_saves=normalize_save_headers(screen.savegame_header_game),
        }
    end

    ---Returns the center of the generated Continue title button.
    ---@param title table
    ---@return integer, integer
    local function continue_title_button_position(title)
        local choices = assert(df_api.main_choice_type,
            'DwarfSpec save-game load requires df.main_choice_type')
        local continue_choice = assert(choices.Continue,
            'DwarfSpec save-game load requires the Continue title choice')
        local ordinal = 0
        local found = false
        for _, choice in ipairs(title.screen.menu_line_id) do
            if choice == continue_choice then
                found = true
                break
            end
            ordinal = ordinal + 1
        end
        assert(found,
            'DwarfSpec save-game load could not find the Continue title choice')
        local width, height = get_window_size()
        return math.floor(width / 2),
            math.floor(height / 2) + ordinal * 3
    end

    ---Returns the center of one generated native title-list button.
    ---@param one_based_index integer
    ---@return integer, integer
    local function native_title_list_item_position(one_based_index)
        local width, height = get_window_size()
        return math.floor(width / 2),
            math.floor(height / 2) + 1 + (one_based_index - 1) * 3
    end

    ---Selects one native title-list item with DFHack-simulated input.
    ---@param title table
    ---@param one_based_index integer
    local function select_native_title_list_item(title, one_based_index)
        assert(type(one_based_index) == 'number' and
                one_based_index % 1 == 0 and one_based_index >= 1,
            'DwarfSpec save-game selection requires a positive item index')
        local x, y = native_title_list_item_position(one_based_index)
        move_native_pointer(x, y)
        title.screen.selected_r = one_based_index - 1
        click_native(title.screen)
    end

    ---Runs one action through the shared map-loaded event command.
    ---@param description string
    ---@param action function
    ---@return any
    local function await_shared_map_loaded(description, action)
        assert(type(description) == 'string' and description ~= '',
            'DwarfSpec map-loaded wait requires a description')
        assert(type(action) == 'function',
            'DwarfSpec map-loaded wait requires an action')
        return await_event(EEvent.MAP_LOADED, {
            description=description,
            trigger=action,
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
        get_title_state=get_native_title_state,
        reach_main_menu=function()
            for _ = 1, 3 do
                local state = get_native_title_state()
                assert(state,
                    'DwarfSpec save-game load requires the title screen')
                if state.mode == 'main' then return end
                local previous_mode = state.mode
                simulate_native_input(state.screen, 'LEAVESCREEN')
                wait_for_save_game_state('return to title main menu',
                    function()
                        local current = get_native_title_state()
                        return current and current.mode ~= previous_mode
                    end)
            end
            error('DwarfSpec could not reach the title main menu', 2)
        end,
        select_continue=function(title)
            local x, y = continue_title_button_position(title)
            move_native_pointer(x, y)
            scheduler_module.wait_frames(scheduler, 1)
            click_native(title.screen)
        end,
        select_world=select_native_title_list_item,
        select_save=select_native_title_list_item,
        await_map_loaded=await_shared_map_loaded,
        capture_input_state=function()
            return pointer_adapter.begin_transient(pointer)
        end,
        wait_until=wait_for_save_game_state,
        get_focus=current_native_focus,
        get_viewscreen=function()
            local screen = current_viewscreen()
            return screen and screen._type
        end,
    })
end

return M
