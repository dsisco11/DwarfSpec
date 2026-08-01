-- Unit contracts for native requested-save loading and confirmation.

local save_game_load = assert(loadfile(
    'src/dwarfspec/automation/save_game_load.lua'))()

describe('save-game load adapter', function()
    local world_loaded
    local loaded_directory
    local title
    local inputs
    local waits
    local restored_input_state
    local requested_world
    local load_screen_visible
    local loader

    ---Builds one normalized title state.
    ---@param mode string
    ---@return table
    local function title_state(mode)
        return {
            mode=mode,
            all_saves={
                {directory_name='region1', world_id='world-a'},
                {directory_name='region2', world_id=requested_world},
            },
            world_saves={
                {directory_name='region1', world_id='world-a'},
                {directory_name='region2', world_id=requested_world},
            },
            game_saves={
                {directory_name='region2-old', world_id=requested_world},
                {directory_name='region2', world_id=requested_world},
            },
        }
    end

    ---Builds one injected native save loader fixture.
    ---@return table
    local function make_dependencies()
        return {
            is_world_loaded=function() return world_loaded end,
            read_world_folder=function() return loaded_directory end,
            get_title_state=function() return title end,
            is_load_screen_visible=function() return load_screen_visible end,
            get_focus=function() return 'title/Default' end,
            get_viewscreen=function() return 'df.viewscreen_titlest' end,
            capture_input_state=function()
                return function() restored_input_state = true end
            end,
            reach_main_menu=function()
                table.insert(inputs, 'REACH_MAIN')
                title = title_state('main')
            end,
            select_continue=function()
                table.insert(inputs, 'CONTINUE')
                title = title_state('world-list')
            end,
            select_world=function(_, index)
                table.insert(inputs, 'WORLD:' .. tostring(index))
                title = title_state('save-list')
            end,
            select_save=function(_, index)
                table.insert(inputs, 'SAVE:' .. tostring(index))
                world_loaded = true
                loaded_directory = 'region2'
                title = nil
                load_screen_visible = false
            end,
            await_map_loaded=function(description, action)
                table.insert(waits, description)
                action()
                return assert(world_loaded,
                    'map-loaded event did not occur: ' .. description)
            end,
            wait_until=function(description, query)
                table.insert(waits, description)
                return assert(query(),
                    'wait query did not complete: ' .. description)
            end,
        }
    end

    before_each(function()
        world_loaded = false
        loaded_directory = nil
        title = nil
        inputs = {}
        waits = {}
        restored_input_state = false
        requested_world = 'world-b'
        load_screen_visible = true
        loader = save_game_load.new(make_dependencies())
    end)

    it('loads the exact requested save through each native title list',
            function()
        assert.is_true(loader:load('region2'))

        assert.same({
            'REACH_MAIN',
            'CONTINUE',
            'WORLD:2',
            'SAVE:2',
        }, inputs)
        assert.equals('region2', loaded_directory)
        assert.is_true(restored_input_state)
        assert.equals(5, #waits)
        assert.matches('wait for save%-game load requested=region2',
            waits[4])
        assert.matches('dismiss save%-game load screen requested=region2',
            waits[5])
    end)

    it('waits for every deferred native title transition', function()
        local dependencies = make_dependencies()
        local pending
        dependencies.select_continue = function()
            table.insert(inputs, 'CONTINUE')
            pending = function() title = title_state('world-list') end
        end
        dependencies.select_world = function(_, index)
            table.insert(inputs, 'WORLD:' .. tostring(index))
            pending = function() title = title_state('save-list') end
        end
        dependencies.select_save = function(_, index)
            table.insert(inputs, 'SAVE:' .. tostring(index))
            pending = function()
                world_loaded = true
                loaded_directory = 'region2'
                title = nil
                pending = function() load_screen_visible = false end
            end
        end
        dependencies.await_map_loaded = function(description, action)
            table.insert(waits, description)
            action()
            assert(pending, 'map-loaded event was not scheduled')
            local callback = pending
            pending = nil
            callback()
            return true
        end
        dependencies.wait_until = function(description, query)
            table.insert(waits, description)
            local value = query()
            if value then return value end
            assert(pending, 'native transition was not scheduled')
            local callback = pending
            pending = nil
            callback()
            return assert(query(),
                'wait query did not complete: ' .. description)
        end
        loader = save_game_load.new(dependencies)

        assert.is_true(loader:load('region2'))
        assert.equals('region2', loaded_directory)
        assert.is_nil(title)
        assert.is_false(load_screen_visible)
        assert.matches('dismiss save%-game load screen requested=region2',
            waits[#waits])
    end)

    it('reports a missing save before sending selection input', function()
        local dependencies = make_dependencies()
        dependencies.reach_main_menu = function()
            table.insert(inputs, 'REACH_MAIN')
            title = title_state('main')
            title.all_saves = {}
        end
        loader = save_game_load.new(dependencies)

        local ok, error_message = pcall(function()
            loader:load('region404')
        end)

        assert.is_false(ok)
        assert.matches('save is missing or unavailable: requested=region404',
            error_message, 1, true)
        assert.same({'REACH_MAIN'}, inputs)
        assert.is_true(restored_input_state)
    end)

    it('reports saves whose world is inactive', function()
        local dependencies = make_dependencies()
        dependencies.select_continue = function()
            table.insert(inputs, 'CONTINUE')
            title = title_state('world-list')
            title.world_saves = {
                {directory_name='region1', world_id='world-a'},
            }
        end
        loader = save_game_load.new(dependencies)

        local ok, error_message = pcall(function()
            loader:load('region2')
        end)

        assert.is_false(ok)
        assert.matches('belongs to an inactive world: requested=region2',
            error_message, 1, true)
        assert.is_true(restored_input_state)
    end)

    it('reports saves absent from the selected active world', function()
        local dependencies = make_dependencies()
        dependencies.select_world = function(_, index)
            table.insert(inputs, 'WORLD:' .. tostring(index))
            title = title_state('save-list')
            title.game_saves = {}
        end
        loader = save_game_load.new(dependencies)

        local ok, error_message = pcall(function()
            loader:load('region2')
        end)

        assert.is_false(ok)
        assert.matches(
            'save is unavailable in its active world: requested=region2',
            error_message, 1, true)
        assert.is_true(restored_input_state)
    end)

    it('reports bounded load timeouts with native diagnostics', function()
        local dependencies = make_dependencies()
        dependencies.select_save = function(_, index)
            table.insert(inputs, 'SAVE:' .. tostring(index))
        end
        dependencies.await_map_loaded = function(description, action)
            table.insert(waits, description)
            action()
            error('map-loaded event did not occur: ' .. description)
        end
        loader = save_game_load.new(dependencies)

        local ok, error_message = pcall(function()
            loader:load('region2')
        end)

        assert.is_false(ok)
        assert.matches('map%-loaded event did not occur: wait for save%-game load',
            error_message)
        assert.matches('observed=<unloaded>', error_message, 1, true)
        assert.matches('focus=title/Default', error_message, 1, true)
        assert.is_true(restored_input_state)
    end)

    it('rejects a different save loaded by native selection', function()
        local dependencies = make_dependencies()
        dependencies.select_save = function(_, index)
            table.insert(inputs, 'SAVE:' .. tostring(index))
            world_loaded = true
            loaded_directory = 'region-wrong'
        end
        loader = save_game_load.new(dependencies)

        local ok, error_message = pcall(function()
            loader:load('region2')
        end)

        assert.is_false(ok)
        assert.matches('loaded the wrong save', error_message, 1, true)
        assert.matches('requested=region2 observed=region%-wrong',
            error_message)
        assert.is_true(restored_input_state)
    end)

    it('rejects loaded and malformed resulting world states', function()
        world_loaded = true
        assert.has_error(function()
            loader:load('region2')
        end, 'DwarfSpec save-game load requires an unloaded world')

        world_loaded = false
        local dependencies = make_dependencies()
        dependencies.read_world_folder = function() return '' end
        loader = save_game_load.new(dependencies)
        local ok, error_message = pcall(function()
            loader:load('region2')
        end)
        assert.is_false(ok)
        assert.matches(
            'DFHack ReadWorldFolder did not return a valid save directory name',
            error_message, 1, true)
        assert.is_true(restored_input_state)
    end)
end)
