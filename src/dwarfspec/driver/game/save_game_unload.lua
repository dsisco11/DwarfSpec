-- Driver-owned save unloading through an injected native options adapter.

local M = {}

---Returns the save-menu entry that discards a world without saving.
---@param dependencies table
---@return any
local function quit_without_saving_option(dependencies)
    local menu_options = assert(dependencies.main_menu_option_type,
        'DwarfSpec save-game unload requires df.main_menu_option_type')
    local option = menu_options.QUIT_WITHOUT_SAVING
    assert(option ~= nil,
        'DwarfSpec save-game unload requires QUIT_WITHOUT_SAVING')
    return option
end

---Finds one menu-option index and visible ordinal by generated enum value.
---@param options table
---@param expected_option any
---@return integer, integer
local function find_option_index(options, expected_option)
    assert(type(options.option) == 'table' or type(options.option) == 'userdata',
        'DwarfSpec save-game unload requires native options entries')
    local ordinal = 0
    for index, option in ipairs(options.option) do
        if option == expected_option then return index, ordinal end
        ordinal = ordinal + 1
    end
    error('DwarfSpec save-game unload could not find QUIT_WITHOUT_SAVING', 2)
end

---Returns the center grid coordinate for one visible native option button.
---@param option_count integer
---@param option_ordinal integer
---@param window_width integer
---@param window_height integer
---@return integer, integer
function M.option_click_position(option_count, option_ordinal, window_width,
        window_height)
    assert(type(option_count) == 'number' and option_count > 0 and
            option_count % 1 == 0,
        'native options count must be a positive integer')
    assert(type(option_ordinal) == 'number' and option_ordinal >= 0 and
            option_ordinal < option_count and option_ordinal % 1 == 0,
        'native option ordinal is outside the visible options')
    assert(type(window_width) == 'number' and window_width > 0 and
            window_width % 1 == 0 and type(window_height) == 'number' and
            window_height > 0 and window_height % 1 == 0,
        'native options click requires positive integer window dimensions')

    local button_height = 3
    local x = math.floor(window_width / 2)
    local first_button_center =
        math.floor((window_height - option_count * button_height) / 2) + 3
    local y = first_button_center + option_ordinal * button_height
    assert(x >= 0 and x < window_width and y >= 0 and y < window_height,
        'native options click position is outside the current window')
    return x, y
end

---Returns the center grid coordinate for the native discard confirmation.
---@param window_width integer
---@param window_height integer
---@return integer, integer
function M.confirm_discard_click_position(window_width, window_height)
    assert(type(window_width) == 'number' and window_width > 0 and
            window_width % 1 == 0 and type(window_height) == 'number' and
            window_height > 0 and window_height % 1 == 0,
        'discard confirmation click requires positive integer window dimensions')
    local x = math.floor(window_width / 2) - 26
    local y = math.floor(window_height / 2) + 4
    assert(x >= 0 and x < window_width and y >= 0 and y < window_height,
        'discard confirmation click position is outside the current window')
    return x, y
end

---Waits for one native discard transition condition.
---@param dependencies table
---@param description string
---@param query function
---@return any
local function wait_for(dependencies, description, query)
    assert(type(dependencies.wait_until) == 'function',
        'DwarfSpec save-game unload requires raw-frame waiting')
    return dependencies.wait_until(description, query)
end

---Limits one diagnostic field to a safe, readable length.
---@param value any
---@return string
local function bounded_field(value)
    local text = tostring(value or '<unknown>')
    if #text <= 64 then return text end
    return text:sub(1, 61) .. '...'
end

---Builds one transition wait description with native-state diagnostics.
---@param dependencies table
---@param operation string
---@param expected_directory string
---@param destination string
---@return string
local function wait_description(dependencies, operation, expected_directory,
        destination)
    local focus = dependencies.get_focus and dependencies.get_focus() or nil
    local viewscreen = dependencies.get_viewscreen and
        dependencies.get_viewscreen() or nil
    local observed_directory
    if dependencies.is_world_loaded() then
        local ok, value = pcall(dependencies.read_world_folder)
        observed_directory = ok and value or '<read-failed>'
    else
        observed_directory = '<unloaded>'
    end
    return ('%s expected=%s destination=%s observed=%s focus=%s viewscreen=%s')
        :format(
        operation, bounded_field(expected_directory),
        bounded_field(destination), bounded_field(observed_directory),
        bounded_field(focus), bounded_field(viewscreen))
end

---Creates one discard adapter with injected native game operations.
---@param dependencies table
---@return table
function M.new(dependencies)
    assert(type(dependencies) == 'table',
        'save-game unload dependencies must be a table')
    assert(type(dependencies.is_world_loaded) == 'function',
        'DwarfSpec save-game unload requires dfhack.isWorldLoaded')
    assert(type(dependencies.read_world_folder) == 'function',
        'DwarfSpec save-game unload requires dfhack.world.ReadWorldFolder')
    assert(type(dependencies.get_options) == 'function',
        'DwarfSpec save-game unload requires native options access')
    assert(type(dependencies.get_screen) == 'function',
        'DwarfSpec save-game unload requires native screen access')
    assert(type(dependencies.open_options) == 'function',
        'DwarfSpec save-game unload requires options input')
    assert(type(dependencies.get_window_size) == 'function',
        'DwarfSpec save-game unload requires native window dimensions')
    assert(type(dependencies.move_pointer) == 'function',
        'DwarfSpec save-game unload requires virtual pointer movement')
    assert(type(dependencies.click_left) == 'function',
        'DwarfSpec save-game unload requires native left-click input')
    assert(type(dependencies.wait_frames) == 'function',
        'DwarfSpec save-game unload requires raw-frame settling')
    assert(type(dependencies.get_title_state) == 'function',
        'DwarfSpec save-game unload requires title-menu inspection')
    local adapter = {}

    ---Discards the expected currently loaded save without saving it.
    ---@param expected_directory string
    ---@param destination string
    ---@return true
    function adapter:unload(expected_directory, destination)
        assert(type(expected_directory) == 'string' and expected_directory ~= '',
            'DwarfSpec save-game unload requires an expected save directory')
        assert(type(destination) == 'string' and destination ~= '',
            'DwarfSpec save-game unload requires a transition destination')
        assert(dependencies.is_world_loaded(),
            'DwarfSpec save-game unload requires a loaded save game')
        assert(dependencies.read_world_folder() == expected_directory,
            'DwarfSpec save-game unload found an unexpected loaded save game')

        local restore_input_state = dependencies.capture_input_state and
            dependencies.capture_input_state() or function() end
        assert(type(restore_input_state) == 'function',
            'DwarfSpec save-game unload input restoration must be a function')
        local ok, result = xpcall(function()
            local options = dependencies.get_options()
            assert(type(options) == 'table' or type(options) == 'userdata',
                'DwarfSpec save-game unload could not access native options')
            local screen = dependencies.get_screen()
            assert(screen ~= nil,
                'DwarfSpec save-game unload could not access the native screen')

            if not options.open then
                dependencies.open_options(screen)
                options = wait_for(dependencies, wait_description(dependencies,
                    'open save-game options', expected_directory,
                    destination),
                    function()
                        local observed = dependencies.get_options()
                        return observed.open and observed or nil
                    end)
            end

            local option_index, option_ordinal = find_option_index(options,
                quit_without_saving_option(dependencies))
            local window_width, window_height =
                dependencies.get_window_size(screen)
            local click_x, click_y = M.option_click_position(
                #options.option, option_ordinal, window_width, window_height)
            dependencies.move_pointer(click_x, click_y)
            dependencies.click_left(screen, options, option_index)
            wait_for(dependencies, wait_description(dependencies,
                'request discard without saving', expected_directory,
                destination), function()
                local observed = dependencies.get_options()
                return observed.fort_quit_without_saving_confirm or
                    observed.adv_quit_without_saving_confirm
            end)
            window_width, window_height =
                dependencies.get_window_size(screen)
            click_x, click_y = M.confirm_discard_click_position(
                window_width, window_height)
            dependencies.move_pointer(click_x, click_y)
            dependencies.click_left(screen, dependencies.get_options())
            wait_for(dependencies, wait_description(dependencies,
                'wait for save game unload', expected_directory,
                destination), function()
                return not dependencies.is_world_loaded()
            end)
            wait_for(dependencies, wait_description(dependencies,
                'wait for title main menu', expected_directory,
                destination), function()
                local state = dependencies.get_title_state()
                return state and state.mode == 'main' and state or nil
            end)
            dependencies.wait_frames(2)
            return true
        end, debug.traceback)
        local restored, restore_error = xpcall(restore_input_state,
            debug.traceback)
        if not restored then error(restore_error, 0) end
        if not ok then error(result, 0) end
        return result
    end

    ---Discards the loaded save and confirms arrival at the title main menu.
    ---An already-visible title main menu is an idempotent no-op.
    ---@return string|nil
    function adapter:exit_to_main_menu()
        if not dependencies.is_world_loaded() then
            local state = dependencies.get_title_state()
            assert(state and state.mode == 'main',
                'DwarfSpec exitToMainMenu requires a loaded save game or ' ..
                    'the title main menu')
            return nil
        end
        local expected_directory = dependencies.read_world_folder()
        assert(type(expected_directory) == 'string' and
                expected_directory ~= '',
            'DFHack ReadWorldFolder did not return a valid save directory name')
        adapter:unload(expected_directory, 'main-menu')
        return expected_directory
    end

    return adapter
end

return M
