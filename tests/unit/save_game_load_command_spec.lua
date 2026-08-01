-- Unit contracts for the live save-game load command binding.

local command = assert(loadfile(
    'src/dwarfspec/commands/save_game_load.lua'))()
local EEvent = require('dwarfspec.state_change_events')

describe('save-game load command binding', function()
    it('binds save-game command dependencies for loading', function()
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
                return assert(query())
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
                gps.mouse_x = x
                gps.mouse_y = y
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
        local modes = {
            MAIN_MENU=10,
            CONTINUE_ACTIVE_WORLD=20,
            CONTINUE_ACTIVE=30,
        }
        local first_header = {
            filename_noext='region1',
            world_header={id1=11, id2=12},
        }
        local second_header = {
            filename_noext='region2',
            world_header={id1=21, id2=22},
        }
        local screen = {
            _type='title-screen-type',
            mode=modes.MAIN_MENU,
            menu_line_id={100, 200},
            savegame_header={first_header, second_header},
            savegame_header_world={first_header},
            savegame_header_game={second_header},
            selected_r=-1,
        }
        local load_screen = {}
        local current_screen = screen
        local simulated = {}
        local gui = {
            simulateInput=function(actual_screen, key)
                table.insert(simulated, {
                    screen=actual_screen,
                    key=key,
                    x=gps.mouse_x,
                    y=gps.mouse_y,
                })
                if key == 'LEAVESCREEN' then
                    actual_screen.mode = modes.MAIN_MENU
                end
            end,
        }
        local event_wait_calls = {}
        local event_occurrence = {}
        local await_event = function(event, options)
            table.insert(event_wait_calls, {
                event=event,
                options=options,
                trigger_called=false,
            })
            options.trigger()
            event_wait_calls[#event_wait_calls].trigger_called = true
            return event_occurrence
        end
        local dfhack_api = {
            isWorldLoaded=function() return false end,
            world={ReadWorldFolder=function() return 'region2' end},
            gui={getCurFocus=function() return {'title/Default'} end},
        }
        local df_api = {
            viewscreen_titlest={
                is_instance=function(_, candidate)
                    return candidate == screen
                end,
            },
            viewscreen_loadgamest={
                is_instance=function(_, candidate)
                    return candidate == load_screen
                end,
            },
            title_mode_type=modes,
            main_choice_type={Continue=200},
        }

        local result = command.new({
            workflow=workflow,
            scheduler_module=scheduler_module,
            scheduler=scheduler,
            wait_settings={timeout_ms=123, frame_budget=456},
            dfhack=dfhack_api,
            df=df_api,
            current_viewscreen=function() return current_screen end,
            get_window_size=function() return 80, 25 end,
            pointer_adapter=pointer_adapter,
            pointer=pointer,
            gui=gui,
            events=EEvent,
            await_event=await_event,
        })

        assert.equals(sentinel, result)
        assert.is_false(captured.is_world_loaded())
        assert.equals('region2', captured.read_world_folder())
        assert.equals('title/Default', captured.get_focus())
        assert.equals('title-screen-type', captured.get_viewscreen())
        assert.is_false(captured.is_load_screen_visible())
        current_screen = load_screen
        assert.is_true(captured.is_load_screen_visible())
        current_screen = screen

        local title = captured.get_title_state()
        assert.equals('main', title.mode)
        assert.equals(screen, title.screen)
        assert.same({
            {directory_name='region1', world_id='11:12'},
            {directory_name='region2', world_id='21:22'},
        }, title.all_saves)
        assert.same({
            {directory_name='region1', world_id='11:12'},
        }, title.world_saves)
        assert.same({
            {directory_name='region2', world_id='21:22'},
        }, title.game_saves)

        captured.select_continue(title)
        assert.same({scheduler=scheduler, count=1}, frame_calls[1])
        assert.same({screen=screen, key='_MOUSE_L', x=40, y=15},
            simulated[1])

        captured.select_world(title, 2)
        assert.equals(1, screen.selected_r)
        assert.same({screen=screen, key='_MOUSE_L', x=40, y=16},
            simulated[2])
        assert.same({
            {operation='set_grid', pointer=pointer, x=40, y=15},
            {operation='set_grid', pointer=pointer, x=40, y=16},
        }, pointer_calls)

        local restore = captured.capture_input_state()
        assert.same({
            operation='begin_transient',
            pointer=pointer,
        }, pointer_calls[3])
        assert.is_false(pointer_restored)
        restore()
        assert.is_true(pointer_restored)

        screen.mode = modes.CONTINUE_ACTIVE
        captured.reach_main_menu()
        assert.equals(modes.MAIN_MENU, screen.mode)
        assert.equals('LEAVESCREEN', simulated[3].key)
        assert.equals('return to title main menu',
            wait_calls[#wait_calls].description)
        assert.same({timeout_ms=123, frame_budget=456},
            wait_calls[#wait_calls].options)

        local action_called = false
        local query_wait_count = #wait_calls
        local occurrence = captured.await_map_loaded(
            'load requested save', function()
            action_called = true
        end)
        assert.equals(event_occurrence, occurrence)
        assert.is_true(action_called)
        assert.equals(query_wait_count, #wait_calls)
        assert.equals(1, #event_wait_calls)
        assert.equals(EEvent.MAP_LOADED, event_wait_calls[1].event)
        assert.equals('load requested save',
            event_wait_calls[1].options.description)
        assert.is_nil(event_wait_calls[1].options.timeout_ms)
        assert.is_true(event_wait_calls[1].trigger_called)
    end)
end)
