-- Native DFHack binding for the save-game load workflow.

local M = {}
local title_menu = require('dwarfspec.driver.commands.title_menu')

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
    local scheduling = assert(dependencies.scheduling,
        'DwarfSpec save-game load command requires scheduling capabilities')
    assert(type(scheduling.wait_until) == 'function' and
            type(scheduling.wait_frames) == 'function',
        'DwarfSpec save-game load command requires wait capabilities')
    local native_game = assert(dependencies.native_game,
        'DwarfSpec save-game load command requires native-game capabilities')
    for _, name in ipairs({
            'is_world_loaded', 'read_world_folder', 'get_focus',
            'current_viewscreen', 'get_window_size', 'simulate_input'}) do
        assert(type(native_game[name]) == 'function',
            'DwarfSpec save-game load command requires native_game.' ..
                name .. '()')
    end
    for _, name in ipairs({
            'title_screen_type', 'title_mode_type', 'load_screen_type',
            'main_choice_type'}) do
        assert(native_game[name] ~= nil,
            'DwarfSpec save-game load command requires native_game.' .. name)
    end
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

    ---Returns the current normalized native title state.
    ---@return table|nil
    local function get_native_title_state()
        local state = title_menu.read(native_game)
        if not state then return nil end
        state.all_saves = normalize_save_headers(state.screen.savegame_header)
        state.world_saves = normalize_save_headers(
            state.screen.savegame_header_world)
        state.game_saves = normalize_save_headers(
            state.screen.savegame_header_game)
        return state
    end

    ---Returns the center of the generated Continue title button.
    ---@param title table
    ---@return integer, integer
    local function continue_title_button_position(title)
        local choices = native_game.main_choice_type
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
        local width, height = native_game.get_window_size()
        return math.floor(width / 2),
            math.floor(height / 2) + ordinal * 3
    end

    ---Returns the center of one generated native title-list button.
    ---@param one_based_index integer
    ---@return integer, integer
    local function native_title_list_item_position(one_based_index)
        local width, height = native_game.get_window_size()
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
        local focus = native_game.get_focus()
        return type(focus) == 'table' and focus[1] or tostring(focus)
    end

    return workflow.new({
        is_world_loaded=native_game.is_world_loaded,
        read_world_folder=native_game.read_world_folder,
        get_title_state=get_native_title_state,
        is_load_screen_visible=function()
            return native_game.load_screen_type:is_instance(
                native_game.current_viewscreen())
        end,
        reach_main_menu=function()
            return title_menu.reach_main_menu(native_game,
                simulate_native_input, wait_for_save_game_state)
        end,
        select_continue=function(title)
            local x, y = continue_title_button_position(title)
            move_native_pointer(x, y)
            scheduling.wait_frames(1)
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
            local screen = native_game.current_viewscreen()
            return screen and screen._type
        end,
    })
end

return M
