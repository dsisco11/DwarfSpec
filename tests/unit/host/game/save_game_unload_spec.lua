-- Unit contracts for native discard without saving.

local save_game_unload = assert(loadfile(
    'src/dwarfspec/host/game/save_game_unload.lua'))()

describe('save-game unload adapter', function()
    local world_loaded
    local loaded_directory
    local options
    local inputs
    local waits
    local settled_frames
    local restored_input_state
    local selection_error
    local selection_confirms
    local screen_available
    local unload_adapter

    ---Builds one injected native discard adapter fixture.
    ---@return table
    local function make_dependencies()
        return {
            is_world_loaded=function() return world_loaded end,
            read_world_folder=function() return loaded_directory end,
            get_options=function() return options end,
            get_screen=function()
                return screen_available and {kind='native-screen'} or nil
            end,
            main_menu_option_type={QUIT_WITHOUT_SAVING='discard'},
            get_focus=function() return 'dwarfmode/Default' end,
            get_viewscreen=function() return 'df.viewscreen_dwarfmodest' end,
            capture_input_state=function()
                return function() restored_input_state = true end
            end,
            open_options=function()
                table.insert(inputs, 'OPTIONS')
                options.open = true
            end,
            get_window_size=function() return 100, 40 end,
            move_pointer=function(x, y)
                table.insert(inputs, ('MOVE_POINTER:%d,%d'):format(x, y))
            end,
            click_left=function(_, _, option_index)
                if option_index ~= nil then
                    table.insert(inputs,
                        'CLICK_LEFT:' .. tostring(option_index))
                    if selection_error then error(selection_error, 0) end
                    options.fort_quit_without_saving_confirm =
                        selection_confirms
                else
                    table.insert(inputs, 'CLICK_LEFT:CONFIRM')
                    world_loaded = false
                end
            end,
            wait_until=function(description, query)
                table.insert(waits, description)
                return assert(query(), 'wait query did not complete: ' ..
                    description)
            end,
            wait_frames=function(count)
                settled_frames = settled_frames + count
            end,
        }
    end

    before_each(function()
        world_loaded = true
        loaded_directory = 'region1'
        options = {
            open=false,
            option={
                'save-and-return',
                'save-and-continue',
                'retire',
                'abandon',
                'discard',
                'settings',
                'return',
            },
            fort_quit_without_saving_confirm=false,
            adv_quit_without_saving_confirm=false,
        }
        inputs = {}
        waits = {}
        settled_frames = 0
        restored_input_state = false
        selection_error = nil
        selection_confirms = true
        screen_available = true
        unload_adapter = save_game_unload.new(make_dependencies())
    end)

    it('opens options, selects the enum-identified discard action, and unloads',
            function()
        assert.is_true(unload_adapter:unload('region1', 'region2'))

        assert.same({
            'OPTIONS',
            'MOVE_POINTER:50,24',
            'CLICK_LEFT:5',
            'MOVE_POINTER:24,24',
            'CLICK_LEFT:CONFIRM',
        }, inputs)
        assert.matches('open save-game options expected=region1 requested=region2',
            waits[1], 1, true)
        assert.matches('observed=region1', waits[1], 1, true)
        assert.matches('request discard without saving expected=region1 requested=region2',
            waits[2], 1, true)
        assert.matches('wait for save game unload expected=region1 requested=region2',
            waits[3], 1, true)
        assert.is_false(world_loaded)
        assert.equals(2, settled_frames)
        assert.is_true(restored_input_state)
    end)

    it('uses an already-open options interface without reopening it', function()
        options.open = true

        assert.is_true(unload_adapter:unload('region1', 'region2'))

        assert.same({
            'MOVE_POINTER:50,24',
            'CLICK_LEFT:5',
            'MOVE_POINTER:24,24',
            'CLICK_LEFT:CONFIRM',
        }, inputs)
        assert.matches('request discard without saving', waits[1], 1, true)
        assert.matches('wait for save game unload', waits[2], 1, true)
    end)

    it('rejects an unexpected loaded save before native input', function()
        local ok, error_message = pcall(function()
            unload_adapter:unload('region2', 'region3')
        end)

        assert.is_false(ok)
        assert.matches('unexpected loaded save game', error_message, 1, true)
        assert.same({}, inputs)
        assert.is_false(restored_input_state)
    end)

    it('restores temporary input state after native-selection failure',
            function()
        selection_error = 'injected selection failure'

        local ok, error_message = pcall(function()
            unload_adapter:unload('region1', 'region2')
        end)

        assert.is_false(ok)
        assert.matches('injected selection failure', error_message, 1, true)
        assert.is_true(restored_input_state)
    end)

    it('reports a confirmation wait failure and restores temporary input state',
            function()
        selection_confirms = false

        local ok, error_message = pcall(function()
            unload_adapter:unload('region1', 'region2')
        end)

        assert.is_false(ok)
        assert.matches('wait query did not complete: request discard without saving',
            error_message, 1, true)
        assert.is_true(restored_input_state)
        assert.is_true(world_loaded)
    end)

    it('reports an unavailable native screen and restores temporary input state',
            function()
        screen_available = false

        local ok, error_message = pcall(function()
            unload_adapter:unload('region1', 'region2')
        end)

        assert.is_false(ok)
        assert.matches('could not access the native screen', error_message,
            1, true)
        assert.is_true(restored_input_state)
        assert.same({}, inputs)
    end)

    it('rejects a missing generated discard action', function()
        unload_adapter = save_game_unload.new(make_dependencies())
        local dependencies = make_dependencies()
        dependencies.main_menu_option_type = {}
        unload_adapter = save_game_unload.new(dependencies)

        local ok, error_message = pcall(function()
            unload_adapter:unload('region1', 'region2')
        end)

        assert.is_false(ok)
        assert.matches('requires QUIT_WITHOUT_SAVING', error_message, 1, true)
        assert.is_true(restored_input_state)
    end)

    it('centers an enum-identified option row at different window sizes',
            function()
        assert.same({132, 42}, {
            save_game_unload.option_click_position(7, 4, 264, 75),
        })
        assert.same({40, 11}, {
            save_game_unload.option_click_position(3, 1, 80, 20),
        })
    end)

    it('centers the native discard confirmation action', function()
        assert.same({106, 41}, {
            save_game_unload.confirm_discard_click_position(264, 75),
        })
        assert.same({24, 24}, {
            save_game_unload.confirm_discard_click_position(100, 40),
        })
    end)

    it('rejects invalid option geometry', function()
        assert.has_error(function()
            save_game_unload.option_click_position(0, 0, 80, 25)
        end, 'native options count must be a positive integer')
        assert.has_error(function()
            save_game_unload.option_click_position(3, 3, 80, 25)
        end, 'native option ordinal is outside the visible options')
        assert.has_error(function()
            save_game_unload.option_click_position(7, 4, 10, 5)
        end, 'native options click position is outside the current window')
        assert.has_error(function()
            save_game_unload.confirm_discard_click_position(20, 10)
        end, 'discard confirmation click position is outside the current window')
    end)
end)
