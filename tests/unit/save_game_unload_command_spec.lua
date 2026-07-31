-- Unit contracts for the live save-game unload command binding.

local command = assert(loadfile(
    'src/dwarfspec/commands/save_game_unload.lua'))()

describe('save-game unload command binding', function()
    it('binds save-game command dependencies for unloading', function()
        local captured
        local sentinel = {}
        local workflow = {
            new=function(dependencies)
                captured = dependencies
                return sentinel
            end,
        }
        local scheduler = {}
        local wait_calls = {}
        local frame_calls = {}
        local scheduler_module = {
            wait_until=function(actual_scheduler, description, query, options)
                table.insert(wait_calls, {
                    scheduler=actual_scheduler,
                    description=description,
                    options=options,
                })
                return query()
            end,
            wait_frames=function(actual_scheduler, count)
                table.insert(frame_calls, {
                    scheduler=actual_scheduler,
                    count=count,
                })
                return count
            end,
        }
        local gps = {
            mouse_x=1,
            mouse_y=2,
            precise_mouse_x=10,
            precise_mouse_y=20,
            tile_pixel_x=8,
            tile_pixel_y=9,
        }
        local enabler = {
            mouse_focus=false,
            tracking_on=0,
            mouse_lbut_down=0,
            mouse_lbut_lift=0,
        }
        local pointer = {}
        local pointer_calls = {}
        local pointer_restored = false
        local pointer_adapter = {
            set_grid=function(actual_pointer, x, y)
                table.insert(pointer_calls, {
                    operation='set_grid',
                    pointer=actual_pointer,
                    x=x,
                    y=y,
                })
            end,
            begin_transient=function(actual_pointer)
                table.insert(pointer_calls, {
                    operation='begin_transient',
                    pointer=actual_pointer,
                })
                return function() pointer_restored = true end
            end,
            with_mouse_focus=function(actual_pointer, operation)
                assert.equals(pointer, actual_pointer)
                return operation()
            end,
            sync=function(actual_pointer)
                assert.equals(pointer, actual_pointer)
            end,
        }
        local options = {option={'discard'}}
        local screen = {_type='native-screen-type'}
        local simulated = {}
        local gui = {
            simulateInput=function(actual_screen, key)
                table.insert(simulated, {screen=actual_screen, key=key})
            end,
        }
        local dfhack_api = {
            isWorldLoaded=function() return true end,
            world={ReadWorldFolder=function() return 'region1' end},
            gui={getCurFocus=function() return {'dwarfmode/Default'} end},
        }
        local df_api = {
            global={game={main_interface={options=options}}},
            main_menu_option_type={QUIT_WITHOUT_SAVING=42},
        }

        local result = command.new({
            workflow=workflow,
            scheduler_module=scheduler_module,
            scheduler=scheduler,
            wait_settings={timeout_ms=321, frame_budget=654},
            dfhack=dfhack_api,
            df=df_api,
            current_viewscreen=function() return screen end,
            get_window_size=function() return 80, 25 end,
            pointer_adapter=pointer_adapter,
            pointer=pointer,
            gui=gui,
        })

        assert.equals(sentinel, result)
        assert.is_true(captured.is_world_loaded())
        assert.equals('region1', captured.read_world_folder())
        assert.equals(options, captured.get_options())
        assert.equals(screen, captured.get_screen())
        assert.equals(df_api.main_menu_option_type,
            captured.main_menu_option_type)
        assert.equals('dwarfmode/Default', captured.get_focus())
        assert.equals('native-screen-type', captured.get_viewscreen())

        captured.open_options(screen)
        captured.click_left(screen)
        assert.same({
            {screen=screen, key='OPTIONS'},
            {screen=screen, key='_MOUSE_L'},
        }, simulated)

        captured.move_pointer(7, 8)
        assert.same({
            operation='set_grid',
            pointer=pointer,
            x=7,
            y=8,
        }, pointer_calls[1])

        local restore = captured.capture_input_state()
        assert.same({
            operation='begin_transient',
            pointer=pointer,
        }, pointer_calls[2])
        assert.is_false(pointer_restored)
        restore()
        assert.is_true(pointer_restored)

        assert.equals('ready', captured.wait_until('wait for unload',
            function() return 'ready' end))
        assert.same({
            scheduler=scheduler,
            description='wait for unload',
            options={timeout_ms=321, frame_budget=654},
        }, wait_calls[1])
        assert.equals(3, captured.wait_frames(3))
        assert.same({scheduler=scheduler, count=3}, frame_calls[1])
    end)
end)
