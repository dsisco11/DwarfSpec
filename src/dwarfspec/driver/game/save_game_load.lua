-- Driver-owned save loading through the native title interface.

local M = {}

---Limits one diagnostic field to a safe, readable length.
---@param value any
---@return string
local function bounded_field(value)
    local text = tostring(value or '<unknown>')
    if #text <= 96 then return text end
    return text:sub(1, 93) .. '...'
end

---Finds one normalized save header by exact directory name.
---@param headers table
---@param directory_name string
---@return table|nil, integer|nil
local function find_directory(headers, directory_name)
    assert(type(headers) == 'table',
        'DwarfSpec save-game load requires native save headers')
    for index, header in ipairs(headers) do
        if header.directory_name == directory_name then
            return header, index
        end
    end
end

---Finds one normalized world header by stable world identity.
---@param headers table
---@param world_id any
---@return table|nil, integer|nil
local function find_world(headers, world_id)
    assert(type(headers) == 'table',
        'DwarfSpec save-game load requires native world headers')
    for index, header in ipairs(headers) do
        if header.world_id == world_id then return header, index end
    end
end

---Reads and validates the currently loaded save directory.
---@param dependencies table
---@return string
local function read_loaded_directory(dependencies)
    local directory_name = dependencies.read_world_folder()
    assert(type(directory_name) == 'string' and directory_name ~= '',
        'DFHack ReadWorldFolder did not return a valid save directory name')
    return directory_name
end

---Builds one native-state diagnostic for a bounded wait.
---@param dependencies table
---@param operation string
---@param requested_directory string
---@return string
local function wait_description(dependencies, operation, requested_directory)
    local observed_directory = '<unloaded>'
    if dependencies.is_world_loaded() then
        local ok, value = pcall(dependencies.read_world_folder)
        observed_directory = ok and value or '<read-failed>'
    end
    local state = dependencies.get_title_state()
    return ('%s requested=%s observed=%s mode=%s focus=%s viewscreen=%s')
        :format(operation, bounded_field(requested_directory),
            bounded_field(observed_directory),
            bounded_field(state and state.mode),
            bounded_field(dependencies.get_focus and
                dependencies.get_focus() or nil),
            bounded_field(dependencies.get_viewscreen and
                dependencies.get_viewscreen() or nil))
end

---Waits for one native title state.
---@param dependencies table
---@param operation string
---@param requested_directory string
---@param predicate function
---@return any
local function wait_for(dependencies, operation, requested_directory,
        predicate)
    return dependencies.wait_until(
        wait_description(dependencies, operation, requested_directory),
        predicate)
end

---Runs one selection action and awaits DFHack's map-loaded event.
---@param dependencies table
---@param requested_directory string
---@param action function
---@return any
local function await_map_loaded(dependencies, requested_directory, action)
    return dependencies.await_map_loaded(
        wait_description(dependencies, 'wait for save-game load',
            requested_directory),
        action)
end

---Creates one requested-save loader with injected native DFHack operations.
---@param dependencies table
---@return table
function M.new(dependencies)
    assert(type(dependencies) == 'table',
        'save-game load dependencies must be a table')
    assert(type(dependencies.is_world_loaded) == 'function',
        'DwarfSpec save-game load requires dfhack.isWorldLoaded')
    assert(type(dependencies.read_world_folder) == 'function',
        'DwarfSpec save-game load requires dfhack.world.ReadWorldFolder')
    assert(type(dependencies.get_title_state) == 'function',
        'DwarfSpec save-game load requires native title inspection')
    assert(type(dependencies.is_load_screen_visible) == 'function',
        'DwarfSpec save-game load requires load-screen inspection')
    assert(type(dependencies.reach_main_menu) == 'function',
        'DwarfSpec save-game load requires title navigation')
    assert(type(dependencies.select_continue) == 'function',
        'DwarfSpec save-game load requires simulated Continue input')
    assert(type(dependencies.select_world) == 'function',
        'DwarfSpec save-game load requires simulated world input')
    assert(type(dependencies.select_save) == 'function',
        'DwarfSpec save-game load requires simulated save input')
    assert(type(dependencies.wait_until) == 'function',
        'DwarfSpec save-game load requires raw-frame waiting')
    assert(type(dependencies.await_map_loaded) == 'function',
        'DwarfSpec save-game load requires map-loaded event waiting')

    local loader = {}

    ---Runs one native input stage and restores transient pointer state.
    ---@param action function
    ---@return any
    function loader:_with_input(action)
        local restore_input_state = dependencies.capture_input_state and
            dependencies.capture_input_state() or function() end
        assert(type(restore_input_state) == 'function',
            'DwarfSpec save-game load input restoration must be a function')
        local ok, result = xpcall(action, debug.traceback)
        local restored, restore_error = xpcall(restore_input_state,
            debug.traceback)
        if not restored then error(restore_error, 0) end
        if not ok then error(result, 0) end
        return result
    end

    ---Reaches the save menu and returns the requested save's world identity.
    ---@param requested_directory string
    ---@return table
    function loader:reach_save_menu(requested_directory)
        assert(not dependencies.is_world_loaded(),
            'DwarfSpec save-game load requires an unloaded world')
        return self:_with_input(function()
            dependencies.reach_main_menu()
            local title = wait_for(dependencies, 'reach title menu',
                requested_directory, function()
                    local state = dependencies.get_title_state()
                    return state and state.mode == 'main' and state or nil
                end)
            local requested = find_directory(title.all_saves,
                requested_directory)
            assert(requested,
                ('DwarfSpec save is missing or unavailable: requested=%s')
                    :format(bounded_field(requested_directory)))
            assert(requested.world_id ~= nil,
                'DwarfSpec save header has no stable world identity')
            return {world_id=requested.world_id}
        end)
    end

    ---Selects the requested world and returns the save-list index.
    ---@param requested_directory string
    ---@param world_id string
    ---@return table
    function loader:select_save_world(requested_directory, world_id)
        return self:_with_input(function()
            local title = assert(dependencies.get_title_state(),
                'DwarfSpec save-game world selection requires title state')
            dependencies.select_continue(title)
            title = wait_for(dependencies, 'open active-world list',
                requested_directory, function()
                    local state = dependencies.get_title_state()
                    return state and state.mode == 'world-list' and state or nil
                end)
            local _, world_index = find_world(title.world_saves, world_id)
            assert(world_index,
                ('DwarfSpec save belongs to an inactive world: requested=%s')
                    :format(bounded_field(requested_directory)))
            dependencies.select_world(title, world_index)
            title = wait_for(dependencies, 'open save list',
                requested_directory, function()
                    local state = dependencies.get_title_state()
                    return state and state.mode == 'save-list' and state or nil
                end)
            local _, save_index = find_directory(title.game_saves,
                requested_directory)
            assert(save_index,
                ('DwarfSpec save is unavailable in its active world: ' ..
                    'requested=%s'):format(
                        bounded_field(requested_directory)))
            return {save_index=save_index}
        end)
    end

    ---Selects one save while the map-loaded event is armed.
    ---@param requested_directory string
    ---@param save_index integer
    ---@return true
    function loader:select_save_and_await_map(requested_directory, save_index)
        return self:_with_input(function()
            local title = assert(dependencies.get_title_state(),
                'DwarfSpec save selection requires title state')
            await_map_loaded(dependencies, requested_directory, function()
                dependencies.select_save(title, save_index)
            end)
            return true
        end)
    end

    ---Verifies the loaded save and the dismissed load screen.
    ---@param requested_directory string
    ---@return string
    function loader:verify_loaded(requested_directory)
        assert(dependencies.is_world_loaded(),
            'DFHack reported map loaded without a loaded world')
        local observed_directory = read_loaded_directory(dependencies)
        assert(observed_directory == requested_directory,
            ('DwarfSpec loaded the wrong save: requested=%s observed=%s')
                :format(bounded_field(requested_directory),
                    bounded_field(observed_directory)))
        wait_for(dependencies, 'dismiss save-game load screen',
            requested_directory, function()
                return not dependencies.is_load_screen_visible()
            end)
        return observed_directory
    end

    ---Loads one selectable save directory and confirms the resulting directory.
    ---@param requested_directory string
    ---@return true
    function loader:load(requested_directory)
        assert(type(requested_directory) == 'string' and
                requested_directory ~= '',
            'DwarfSpec save-game load requires a save directory name')
        assert(not dependencies.is_world_loaded(),
            'DwarfSpec save-game load requires an unloaded world')

        local menu = self:reach_save_menu(requested_directory)
        local selection = self:select_save_world(requested_directory,
            menu.world_id)
        self:select_save_and_await_map(requested_directory,
            selection.save_index)
        self:verify_loaded(requested_directory)
        return true
    end

    return loader
end

return M
