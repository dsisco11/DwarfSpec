-- Unit contracts for public mount commands on the run-scoped ds namespace.

local cleanup = assert(loadfile(
    'src/dwarfspec/host/execution/cleanup.lua'))()
local component = assert(loadfile('src/dwarfspec/driver/mount/component.lua'))()
local render_tracker = assert(loadfile(
    'src/dwarfspec/driver/render/render_tracker.lua'))()
local ds_factory = assert(loadfile(
    'src/dwarfspec/ds.lua'))()
local interaction_target = assert(loadfile(
    'src/dwarfspec/driver/subjects/interaction_target.lua'))()
local lua_view_adapter = assert(loadfile(
    'src/dwarfspec/driver/subjects/lua_view_adapter.lua'))()
local EventType = require('dwarfspec.protocol.enums.event_types')
local EMouseButton = require('dwarfspec.driver.input.mouse_buttons')
local EInputState = require('dwarfspec.driver.input.input_states')
local EPointerSpace = require('dwarfspec.driver.input.pointer_spaces')
local EPointerAnchor = require('dwarfspec.driver.input.pointer_anchors')
local EScreenOrigin = require('dwarfspec.driver.screen_origins')
local EEvent = require('dwarfspec.driver.state_change_events')
local EFieldMode =
    require('dwarfspec.driver.subjects.native_game_ui_path').EFieldMode
local TestStatus = require('dwarfspec.protocol.enums.test_statuses')

---Creates a minimal callable class with DFHack defclass-compatible shape.
---@param parent table|nil
---@return table
local function make_class(parent)
    local class = {ATTRS={}}
    class.__index = class
    class.super = parent
    setmetatable(class, {
        __index=parent,
        __call=function(self, attributes)
            local instance = {}
            for key, value in pairs(attributes or {}) do
                instance[key] = value
            end
            return setmetatable(instance, self)
        end,
    })
    return class
end

---Creates one injected native widget fixture with exact ordered children.
---@param name string|nil
---@param type_name string
---@param children table[]|nil
---@param fields table|nil
---@return table
local function make_native_widget(name, type_name, children, fields)
    local widget = {
        name=name,
        _type={_name=type_name, _fields={}},
        children=children or {},
    }
    for key, value in pairs(fields or {}) do widget[key] = value end
    return widget
end

describe('DwarfSpec public mount commands', function()
    local ds
    local registry
    local reset
    local screen
    local native_screen
    local native_root
    local current_native_screen
    local native_df_screen
    local run
    local TestWidget
    local TestOverlay
    local TestScreen
    local published
    local current_tracker
    local original_dfhack
    local original_df
    local original_gui
    local original_overlay_plugin
    local overlay_state
    local simulated_inputs
    local simulate_input_failure
    local simulate_input_dispatch
    local wait_until_calls
    local component_mount_calls
    local native_widget_lookup_calls
    local native_invalidation_count
    local focus_queries
    local focus_match_queries
    local dfhack_time
    local save_directory_name
    local world_loaded
    local save_game_unload_calls
    local save_game_load_calls
    local event_wait_calls
    local map_view_position
    local map_view_dimensions
    local map_view_dimensions_failure
    local map_view_get_failure
    local map_view_set_failure
    local game_speed_set_failure
    local game_speed_ratio_override
    local original_native_render_dispatcher
    local native_render_failure
    local suppress_native_render
    local wait_until_failure
    local wait_until_dispatch
    local screen_cells
    local screen_default_ch
    local screen_read_calls
    local window_size_calls

    ---Returns the stable lookup key for one zero-based screen cell.
    ---@param x integer
    ---@param y integer
    ---@return string
    local function screen_cell_key(x, y)
        return x .. ',' .. y
    end

    ---Writes one exact byte string into the injected rendered screen.
    ---@param x integer
    ---@param y integer
    ---@param text string
    local function write_screen_text(x, y, text)
        for index = 1, #text do
            screen_cells[screen_cell_key(x + index - 1, y)] = {
                ch=text:byte(index),
            }
        end
    end

    ---Installs one declared main-interface path ending in a native widget.
    ---@param final_widget table|nil
    ---@return table
    local function install_game_ui(final_widget)
        final_widget = final_widget or make_native_widget(
            'Dead/Missing', 'df.widget_text', nil, {
                str='Deceased citizens',
                rect={x1=10, y1=5, x2=24, y2=7},
                flag={
                    VISIBILITY_VISIBLE=true,
                    VISIBILITY_ACTIVE=true,
                },
            })
        local tabs = make_native_widget(
            'Tabs', 'df.widget_container', {final_widget})
        local creatures = make_native_widget(
            'creatures', 'df.widget_container', {tabs})
        local info = make_native_widget(
            'info', 'df.widget_container', {creatures})
        info._type._fields.creatures = {
            name='creatures',
            mode=EFieldMode.SUBSTRUCT,
        }
        info.creatures = creatures
        local main_interface = {
            _type={_name='df.main_interface', _fields={
                info={name='info', mode=EFieldMode.SUBSTRUCT},
            }},
            info=info,
        }
        df.global.game = {main_interface=main_interface}
        df.widget = {
            is_instance=function(_, value)
                return type(value) == 'table' and
                    value._type ~= nil and
                    value ~= main_interface
            end,
        }
        df.widget_container = {
            is_instance=function(_, value)
                return type(value) == 'table' and value._type and
                    value._type._name == 'df.widget_container'
            end,
        }
        return {
            main_interface=main_interface,
            info=info,
            creatures=creatures,
            tabs=tabs,
            final_widget=final_widget,
            path={'info', 'creatures', 'Tabs', 'Dead/Missing'},
        }
    end

    before_each(function()
        original_dfhack = rawget(_G, 'dfhack')
        original_df = rawget(_G, 'df')
        original_gui = package.loaded.gui
        original_overlay_plugin = package.loaded['plugins.overlay']
        overlay_state = {db={}, config={}, index={}}
        local overlay_plugin = {
            get_state=function() return overlay_state end,
        }
        overlay_plugin.render_viewscreen_widgets=function(...)
            if native_render_failure then
                error(native_render_failure, 0)
            end
            return ...
        end
        original_native_render_dispatcher =
            overlay_plugin.render_viewscreen_widgets
        package.loaded['plugins.overlay'] = overlay_plugin
        screen = nil
        component_mount_calls = 0
        native_widget_lookup_calls = 0
        native_invalidation_count = 0
        focus_queries = {}
        focus_match_queries = {}
        dfhack_time = 67890
        save_directory_name = 'region1'
        world_loaded = true
        save_game_unload_calls = {}
        save_game_load_calls = {}
        event_wait_calls = {}
        map_view_position = {x=12, y=34, z=5}
        map_view_dimensions = {
            map_x1=3,
            map_x2=12,
            map_y1=4,
            map_y2=10,
        }
        map_view_dimensions_failure = nil
        map_view_get_failure = nil
        map_view_set_failure = nil
        game_speed_set_failure = nil
        game_speed_ratio_override = nil
        native_render_failure = nil
        suppress_native_render = false
        wait_until_failure = nil
        wait_until_dispatch = nil
        simulated_inputs = {}
        simulate_input_failure = nil
        simulate_input_dispatch = nil
        wait_until_calls = 0
        screen_cells = {}
        screen_default_ch = nil
        screen_read_calls = {}
        window_size_calls = 0
        rawset(_G, 'dfhack', {
            getTickCount=function() return dfhack_time end,
            isWorldLoaded=function() return world_loaded end,
            world={
                ReadWorldFolder=function() return save_directory_name end,
            },
            screen={
                getMousePos=function() return 90, 91 end,
                getMousePixels=function() return 900, 910 end,
                getWindowSize=function()
                    window_size_calls = window_size_calls + 1
                    return 80, 25
                end,
                readTile=function(x, y)
                    screen_read_calls[#screen_read_calls + 1] = {x=x, y=y}
                    local pen = screen_cells[screen_cell_key(x, y)]
                    if pen ~= nil then return pen end
                    if screen_default_ch ~= nil then
                        return {ch=screen_default_ch}
                    end
                    return nil
                end,
            },
            gui={
                getMousePos=function(allow_out_of_bounds)
                    return {
                        x=df.global.gps.precise_mouse_x,
                        y=df.global.gps.precise_mouse_y,
                        z=allow_out_of_bounds and 1 or 0,
                    }, 'native-map-result'
                end,
                getWidget=function(parent, segment)
                    native_widget_lookup_calls =
                        native_widget_lookup_calls + 1
                    local children = parent.children or {}
                    if type(segment) == 'number' then
                        return children[segment + 1]
                    end
                    for _, child in ipairs(children) do
                        if child.name == segment then return child end
                    end
                    return nil
                end,
                getWidgetChildren=function(parent)
                    local result = {}
                    for index, child in ipairs(parent.children or {}) do
                        result[index] = child
                    end
                    return result
                end,
                getFocusStrings=function(target)
                    table.insert(focus_queries, target)
                    return target.focus_list or {}
                end,
                matchFocusString=function(path)
                    table.insert(focus_match_queries, path)
                    return path == 'dwarfmode/Default'
                end,
            },
        })
        rawset(_G, 'df', {
            global={
                cur_year_tick=12345,
                pause_state=false,
                gps={
                    mouse_x=4,
                    mouse_y=5,
                    precise_mouse_x=40,
                    precise_mouse_y=50,
                    dimx=80,
                    dimy=25,
                    screen_pixel_x=800,
                    screen_pixel_y=200,
                    tile_pixel_x=10,
                    tile_pixel_y=8,
                },
                enabler={
                    fps=100,
                    gfps=50,
                    fps_per_gfps=2,
                    mouse_focus=false,
                    tracking_on=0,
                    mouse_lbut_down=0,
                    mouse_lbut_lift=0,
                    mouse_rbut_down=0,
                    mouse_rbut_lift=0,
                    mouse_mbut_down=0,
                    mouse_mbut_lift=0,
                },
            },
        })
        package.loaded.gui = {
            simulateInput=function(native_screen, key)
                assert(native_screen ~= nil,
                    'simulated input requires an explicit target screen')
                if simulate_input_failure then
                    error(simulate_input_failure)
                end
                table.insert(simulated_inputs, {
                    screen=native_screen,
                    key=key,
                    x=df.global.gps.mouse_x,
                    y=df.global.gps.mouse_y,
                    pixel_x=df.global.gps.precise_mouse_x,
                    pixel_y=df.global.gps.precise_mouse_y,
                    mouse_focus=df.global.enabler.mouse_focus,
                    tracking_on=df.global.enabler.tracking_on,
                    left_down=df.global.enabler.mouse_lbut_down,
                    left_lift=df.global.enabler.mouse_lbut_lift,
                    right_down=df.global.enabler.mouse_rbut_down,
                    right_lift=df.global.enabler.mouse_rbut_lift,
                    middle_down=df.global.enabler.mouse_mbut_down,
                    middle_lift=df.global.enabler.mouse_mbut_lift,
                })
                if simulate_input_dispatch then
                    simulate_input_dispatch(native_screen, key)
                end
                current_tracker:completed()
            end,
        }
        local Widget = make_class()
        local OverlayWidget = make_class(Widget)
        local ZScreen = make_class()
        TestWidget = make_class(Widget)
        TestOverlay = make_class(OverlayWidget)
        TestScreen = make_class(ZScreen)
        local boundary = component.new({
            Widget=Widget,
            OverlayWidget=OverlayWidget,
            ZScreen=ZScreen,
        })
        published = {}
        local now = 10
        run = {
            run_id='ds-mount-test',
            scheduler_state={},
            event_publisher={
                now_ms=function()
                    now = now + 2
                    return now
                end,
                publish=function(event_type, payload)
                    table.insert(published, {
                        type=event_type,
                        payload=payload,
                    })
                end,
            },
        }
        registry = cleanup.new(run)
        local scheduler = {run=run}
        local scheduler_module = {
            wait_frames=function() return 1 end,
            wait_ticks=function() return 2 end,
            wait_until=function(_, _, query)
                wait_until_calls = wait_until_calls + 1
                if wait_until_failure then
                    error(wait_until_failure, 0)
                end
                if wait_until_dispatch then wait_until_dispatch() end
                local result = query()
                if not result and current_tracker then
                    current_tracker:completed()
                    result = query()
                end
                return assert(result)
            end,
        }
        native_root = {
            kind='native-widget-root',
            _type={_name='df.widget_container'},
            children={},
        }
        native_screen = {
            name='native-screen',
            focus_list={'dwarfmode/Default', 'dwarfmode/Info'},
            widgets=native_root,
            show_calls=0,
            dismiss_calls=0,
            resize_calls=0,
            replace_calls=0,
            navigation_calls=0,
        }
        current_native_screen = native_screen
        native_df_screen = native_screen
        ds, reset = ds_factory.new('.',
            {project_root='.', package_root='.'},
            scheduler_module, scheduler, cleanup, registry,
            {settings={}, commands={
                sample_success={
                    callback=function(_, value) return 'ok:' .. value end,
                },
                sample_failure={
                    callback=function() error('deliberate command failure') end,
                },
            }}, {
                boundary=boundary,
                current_viewscreen=function()
                    return current_native_screen
                end,
                get_map_view_position=function()
                    if map_view_get_failure then
                        error(map_view_get_failure, 0)
                    end
                    return map_view_position.x, map_view_position.y,
                        map_view_position.z
                end,
                set_map_view_position=function(x, y, z)
                    if map_view_set_failure then
                        error(map_view_set_failure, 0)
                    end
                    map_view_position = {x=x, y=y, z=z}
                    return true
                end,
                get_map_view_dimensions=function()
                    if map_view_dimensions_failure then
                        error(map_view_dimensions_failure, 0)
                    end
                    return map_view_dimensions
                end,
                set_game_speed=function(enabler, tps, speed_ratio)
                    if game_speed_set_failure then
                        error(game_speed_set_failure, 0)
                    end
                    enabler.fps = tps
                    enabler.fps_per_gfps =
                        game_speed_ratio_override or speed_ratio
                    return true
                end,
                save_game_unloader={
                    unload=function(_, loaded_directory,
                            requested_directory)
                        table.insert(save_game_unload_calls, {
                            loaded_directory=loaded_directory,
                            requested_directory=requested_directory,
                        })
                        world_loaded = false
                    end,
                },
                save_game_loader={
                    load=function(_, requested_directory)
                        table.insert(save_game_load_calls,
                            requested_directory)
                        world_loaded = true
                        save_directory_name = requested_directory
                    end,
                },
                await_event=function(event, options)
                    local occurrence = {
                        event=event,
                        options=options,
                    }
                    table.insert(event_wait_calls, occurrence)
                    return occurrence
                end,
                native_viewscreen=function() return native_df_screen end,
                is_native_widget_root=function(root)
                    return root and root._type and
                        root._type._name == 'df.widget_container'
                end,
                is_native_widget_container=function(widget)
                    return widget._type._name == 'df.widget_container'
                end,
                invalidate_native_screen=function()
                    native_invalidation_count =
                        native_invalidation_count + 1
                    if suppress_native_render then return end
                    return package.loaded['plugins.overlay']
                        .render_viewscreen_widgets(
                            'native-screen', current_native_screen)
                end,
                render_tracker_factory=function()
                    current_tracker = render_tracker.new(
                        scheduler_module, scheduler)
                    return current_tracker
                end,
                adapter_factory=function()
                    return {
                        mount=function(_, mount, prepared)
                            component_mount_calls =
                                component_mount_calls + 1
                            screen = {
                                active=true,
                                invalidation_count=0,
                                _native=native_screen,
                                isActive=function(self) return self.active end,
                                ---Records an invalidation and its render.
                                ---@param self table
                                invalidate=function(self)
                                    self.invalidation_count =
                                        self.invalidation_count + 1
                                    current_tracker:completed()
                                end,
                            }
                            mount.render_tracker:completed()
                            return {
                                root=prepared.component,
                                host_screen=screen,
                                interaction_target=
                                    interaction_target.new_owned_screen(
                                        screen, {
                                            is_active=function(candidate)
                                                return candidate:isActive()
                                            end,
                                            resolve_native_screen=
                                                function(candidate)
                                                    return ds_factory.resolve_native_screen(
                                                        candidate, function()
                                                            return native_screen
                                                        end)
                                                end,
                                        }),
                                subject_source=
                                    lua_view_adapter.new_source(
                                        prepared.component),
                            }
                        end,
                        unmount=function()
                            screen.active = false
                        end,
                    }
                end,
            }, {
                run_id=run.run_id,
                project={
                    resolve_lua_source=function(source_path)
                        return {
                            relative_path=source_path,
                            absolute_path=source_path,
                        }
                    end,
                },
                cleanup={
                    mark=function() return cleanup.mark(registry) end,
                    register=function(name, action)
                        return cleanup.push(registry, name, action)
                    end,
                    rollback=function(marker, reason)
                        return cleanup.run_from(registry, marker, reason)
                    end,
                },
                recurring={
                    schedule=function()
                        error('unexpected recurring operation scheduling')
                    end,
                    cancel=function() end,
                    is_scheduled=function() return false end,
                    report_failure=function()
                        error('unexpected recurring operation failure')
                    end,
                },
                overlay={
                    destination_directory='unused/overlay',
                    config_path='unused/overlay.json',
                    isfile=function() return false end,
                    read_file=function()
                        error('unexpected overlay file read')
                    end,
                    write_file=function()
                        error('unexpected overlay file write')
                    end,
                    remove_file=function()
                        error('unexpected overlay file removal')
                    end,
                    rescan=function()
                        error('unexpected overlay rescan')
                    end,
                    registered_names=function() return {} end,
                    is_enabled=function() return false end,
                    disable=function()
                        error('unexpected overlay disable')
                    end,
                },
            })
    end)

    it('resets the implicit mount before and after examples idempotently',
            function()
        local mounted = ds.mount(TestWidget, {name='reset-root'})

        reset('after example')

        assert.is_false(screen.active)
        assert.equals(0, cleanup.pending_count(registry))
        assert.has_error(function() mounted:raw() end,
            'stage=retained_subject_reacquisition ' ..
            'DwarfSpec subject raw access rejected stale subject ' ..
            'control_path="<root>" from mount 1; no current mount exists')
        reset('before example')
        assert.equals(0, cleanup.pending_count(registry))
    end)

    after_each(function()
        local cleanup_ok = cleanup.run(registry, 'ds command test teardown')
        assert.equals(original_native_render_dispatcher,
            package.loaded['plugins.overlay']
                .render_viewscreen_widgets)
        package.loaded.gui = original_gui
        package.loaded['plugins.overlay'] = original_overlay_plugin
        rawset(_G, 'dfhack', original_dfhack)
        rawset(_G, 'df', original_df)
        assert.is_true(cleanup_ok)
        assert.equals(0, cleanup.pending_count(registry))
        if screen then assert.is_false(screen.active) end
    end)

    it('mounts, selects from, roots, and unmounts the implicit component',
            function()
        local child = {view_id='child', subviews={}}
        local mounted = ds.mount(TestWidget, {
            name='root',
            subviews={child, child=child},
        })

        assert.equals('native', ds.ESubjectSource.NATIVE)
        assert.equals('overlay', ds.ESubjectSource.OVERLAY)
        assert.equals('root', mounted:raw().name)
        assert.equals(mounted:raw(), ds.root():raw())
        local selected = ds.get('child')
        assert.equals(child, selected:raw())
        assert.equals('child', selected.control_path)
        local tree = ds.capture_view_tree('implicit-tree')
        assert.equals('child', tree.children[1].view_id)
        assert.is_true(screen.active)

        ds.unmount()

        assert.is_false(screen.active)
        assert.equals(0, cleanup.pending_count(registry))
    end)

    it('exposes unit commands only on the run-scoped namespace', function()
        assert.is_function(ds.setUnitSpeed)
        assert.is_function(ds.setUnitPos)
        assert.is_nil(ds_factory.setUnitSpeed)
        assert.is_nil(ds_factory.setUnitPos)
    end)

    it('returns the current world tick without requiring a mount', function()
        assert.equals(12345, ds.getTick())
        df.global.cur_year_tick = 12346
        assert.equals(12346, ds.getTick())

        df.global.cur_year_tick = nil
        assert.has_error(function() ds.getTick() end,
            'DwarfSpec getTick requires a loaded world with a valid ' ..
                'df.global.cur_year_tick')
    end)

    it('waits for simulation ticks without requiring a mount', function()
        assert.equals(2, ds.wait_ticks(2))
    end)

    it('exports immutable event identifiers and delegates event awaiting',
            function()
        local options = {
            description='wait for a new map',
            timeout_ms=250,
        }

        local occurrence = ds.awaitEvent(ds.EEvent.MAP_LOADED, options)

        assert.equals(EEvent.WORLD_LOADED, ds.EEvent.WORLD_LOADED)
        assert.equals(EEvent.WORLD_UNLOADED, ds.EEvent.WORLD_UNLOADED)
        assert.equals(EEvent.MAP_LOADED, ds.EEvent.MAP_LOADED)
        assert.equals(EEvent.MAP_UNLOADED, ds.EEvent.MAP_UNLOADED)
        assert.equals(EEvent.VIEWSCREEN_CHANGED,
            ds.EEvent.VIEWSCREEN_CHANGED)
        assert.equals(EEvent.PAUSED, ds.EEvent.PAUSED)
        assert.equals(EEvent.UNPAUSED, ds.EEvent.UNPAUSED)
        assert.has_error(function()
            ds.EEvent.MAP_LOADED = 'changed'
        end, 'Enums are immutable.')
        assert.equals(1, #event_wait_calls)
        assert.equals(EEvent.MAP_LOADED, event_wait_calls[1].event)
        assert.equals(options, event_wait_calls[1].options)
        assert.equals(event_wait_calls[1], occurrence)
    end)

    it('returns whether the game is paused without requiring a mount',
            function()
        assert.is_false(ds.isGamePaused())
        df.global.pause_state = true
        assert.is_true(ds.isGamePaused())

        df.global.pause_state = nil
        assert.has_error(function() ds.isGamePaused() end,
            'DwarfSpec isGamePaused requires a valid ' ..
                'df.global.pause_state')
    end)

    it('sets and restores the game pause state without requiring a mount',
            function()
        assert.is_true(ds.setGamePaused(true))
        assert.is_true(ds.isGamePaused())
        assert.is_true(
            run.mount_cleanup_probe().game_pause_state_active)
        assert.equals(1, cleanup.pending_count(registry))

        assert.is_false(ds.setGamePaused(false))
        assert.is_false(ds.isGamePaused())
        assert.equals(1, cleanup.pending_count(registry))

        assert.is_true(ds.setGamePaused(true))
        reset('game pause state example cleanup')

        assert.is_false(ds.isGamePaused())
        assert.is_false(
            run.mount_cleanup_probe().game_pause_state_active)
        assert.equals(0, cleanup.pending_count(registry))
    end)

    it('validates the requested game pause state before scheduling cleanup',
            function()
        for _, value in ipairs({0, 'true', {}}) do
            assert.has_error(function()
                ds.setGamePaused(value)
            end, 'game pause state must be a boolean')
        end
        assert.is_false(ds.isGamePaused())
        assert.equals(0, cleanup.pending_count(registry))
    end)

    it('returns the current game speed without a mount or cleanup',
            function()
        local enabler = df.global.enabler

        assert.equals(100, ds.getGameSpeed())
        enabler.fps = 120
        assert.equals(120, ds.getGameSpeed())
        assert.equals(0, cleanup.pending_count(registry))
        assert.is_false(run.mount_cleanup_probe().game_speed_active)
    end)

    it('validates native game speed before returning it', function()
        local enabler = df.global.enabler
        for _, value in ipairs({
                0, -1, 1.5, '100', 0 / 0, math.huge, -math.huge}) do
            enabler.fps = value
            assert.has_error(function()
                ds.getGameSpeed()
            end, 'DwarfSpec getGameSpeed requires a valid positive ' ..
                'integer df.global.enabler.fps')
        end
        assert.equals(0, cleanup.pending_count(registry))

        df.global.enabler = nil
        assert.has_error(function()
            ds.getGameSpeed()
        end, 'DwarfSpec getGameSpeed requires df.global.enabler')
        assert.equals(0, cleanup.pending_count(registry))
    end)

    it('sets and restores the native game speed without a mount',
            function()
        local enabler = df.global.enabler

        assert.equals(120, ds.setGameSpeed(120))
        assert.equals(120, enabler.fps)
        assert.equals(2.4, enabler.fps_per_gfps)
        assert.is_true(run.mount_cleanup_probe().game_speed_active)
        assert.equals(1, cleanup.pending_count(registry))

        enabler.gfps = 60
        assert.equals(180, ds.setGameSpeed(180))
        assert.equals(180, enabler.fps)
        assert.equals(3, enabler.fps_per_gfps)
        assert.equals(1, cleanup.pending_count(registry))

        reset('game speed example cleanup')

        assert.equals(100, enabler.fps)
        assert.equals(2, enabler.fps_per_gfps)
        assert.equals(60, enabler.gfps)
        assert.is_false(run.mount_cleanup_probe().game_speed_active)
        assert.equals(0, cleanup.pending_count(registry))
    end)

    it('validates game speed and native state before owning cleanup',
            function()
        local nan = 0 / 0
        for _, value in ipairs({
                0, -1, 1.5, '100', nan, math.huge, -math.huge}) do
            assert.has_error(function()
                ds.setGameSpeed(value)
            end, 'game speed must be a positive integer TPS target')
        end
        assert.equals(0, cleanup.pending_count(registry))

        local enabler = df.global.enabler
        local cases = {
            {
                field='fps',
                value=0,
                expected='DwarfSpec setGameSpeed requires a valid positive ' ..
                    'integer df.global.enabler.fps',
            },
            {
                field='gfps',
                value=0,
                expected='DwarfSpec setGameSpeed requires a valid positive ' ..
                    'df.global.enabler.gfps',
            },
            {
                field='fps_per_gfps',
                value=nan,
                expected='DwarfSpec setGameSpeed requires a valid ' ..
                    'df.global.enabler.fps_per_gfps',
            },
        }
        for _, case in ipairs(cases) do
            enabler.fps = 100
            enabler.gfps = 50
            enabler.fps_per_gfps = 2
            enabler[case.field] = case.value
            assert.has_error(function()
                ds.setGameSpeed(120)
            end, case.expected)
            assert.equals(0, cleanup.pending_count(registry))
        end

        df.global.enabler = nil
        assert.has_error(function()
            ds.setGameSpeed(120)
        end, 'DwarfSpec setGameSpeed requires df.global.enabler')
        assert.equals(0, cleanup.pending_count(registry))
    end)

    it('retains restoration after a game-speed setter failure', function()
        local enabler = df.global.enabler
        game_speed_set_failure = 'injected game-speed setter failure'

        local ok, failure = pcall(ds.setGameSpeed, 120)

        assert.is_false(ok)
        assert.matches('injected game-speed setter failure', failure, 1, true)
        assert.is_true(run.mount_cleanup_probe().game_speed_active)
        assert.equals(1, cleanup.pending_count(registry))

        game_speed_set_failure = nil
        reset('failed game speed setter cleanup')
        assert.equals(100, enabler.fps)
        assert.equals(2, enabler.fps_per_gfps)
        assert.is_false(run.mount_cleanup_probe().game_speed_active)
    end)

    it('restores after game-speed ratio verification fails', function()
        local enabler = df.global.enabler
        game_speed_ratio_override = 999

        assert.has_error(function()
            ds.setGameSpeed(120)
        end, 'DFHack did not apply the requested game speed ratio')
        assert.equals(120, enabler.fps)
        assert.equals(999, enabler.fps_per_gfps)
        assert.is_true(run.mount_cleanup_probe().game_speed_active)

        game_speed_ratio_override = nil
        reset('failed game speed verification cleanup')
        assert.equals(100, enabler.fps)
        assert.equals(2, enabler.fps_per_gfps)
    end)

    it('reports game-speed restoration failures through cleanup', function()
        ds.setGameSpeed(120)
        game_speed_set_failure = 'injected game-speed restore failure'

        local ok, failure = pcall(
            reset, 'failed game speed restoration')

        assert.is_false(ok)
        assert.matches('restore game speed', failure, 1, true)
        assert.matches('injected game-speed restore failure',
            failure, 1, true)
        assert.is_true(run.mount_cleanup_probe().game_speed_active)
        assert.equals(0, cleanup.pending_count(registry))
    end)

    it('returns the current DFHack time without requiring a mount', function()
        assert.equals(67890, ds.getTime())
        dfhack_time = 67891
        assert.equals(67891, ds.getTime())

        dfhack.getTickCount = nil
        assert.has_error(function() ds.getTime() end,
            'DwarfSpec getTime requires dfhack.getTickCount')
    end)

    it('returns the loaded save directory name without requiring a mount',
            function()
        assert.equals('region1', ds.getSaveDirectoryName())
        save_directory_name = 'region2'
        assert.equals('region2', ds.getSaveDirectoryName())
        assert.equals(0, cleanup.pending_count(registry))

        world_loaded = false
        assert.has_error(function() ds.getSaveDirectoryName() end,
            'DwarfSpec getSaveDirectoryName requires a loaded save game')

        world_loaded = true
        save_directory_name = ''
        assert.has_error(function() ds.getSaveDirectoryName() end,
            'DFHack ReadWorldFolder did not return a valid save directory name')

        dfhack.world = nil
        assert.has_error(function() ds.getSaveDirectoryName() end,
            'DwarfSpec getSaveDirectoryName requires ' ..
                'dfhack.world.ReadWorldFolder')
    end)

    it('exports and delegates save-game mounting without cleanup ownership',
            function()
        assert.equals('function', type(ds.mountSaveGame))

        assert.equals('region1', ds.mountSaveGame('region1'))
        assert.same({}, save_game_unload_calls)
        assert.same({}, save_game_load_calls)
        assert.equals(0, cleanup.pending_count(registry))

        assert.equals('region2', ds.mountSaveGame('region2'))
        assert.same({
            {
                loaded_directory='region1',
                requested_directory='region2',
            },
        }, save_game_unload_calls)
        assert.same({'region2'}, save_game_load_calls)
        assert.equals('region2', ds.getSaveDirectoryName())
        assert.equals(0, cleanup.pending_count(registry))

        world_loaded = false
        assert.equals('region3', ds.mountSaveGame('region3'))
        assert.equals(1, #save_game_unload_calls)
        assert.same({'region2', 'region3'}, save_game_load_calls)
        assert.equals('region3', ds.getSaveDirectoryName())
        assert.equals(0, cleanup.pending_count(registry))
    end)

    it('validates mountSaveGame arguments before adapter delegation',
            function()
        assert.has_error(function() ds.mountSaveGame() end,
            'DwarfSpec mountSaveGame requires exactly one save directory name')
        assert.has_error(function() ds.mountSaveGame('region1', 'extra') end,
            'DwarfSpec mountSaveGame requires exactly one save directory name')
        assert.has_error(function() ds.mountSaveGame('../region1') end,
            'DwarfSpec mountSaveGame requires one directory name, not a path')
        assert.same({}, save_game_unload_calls)
        assert.same({}, save_game_load_calls)
    end)

    it('matches the current DFHack focus without requiring a mount',
            function()
        assert.is_true(ds.hasFocus('dwarfmode/Default'))
        assert.is_false(ds.hasFocus('dwarfmode/Info'))
        assert.same({'dwarfmode/Default', 'dwarfmode/Info'},
            focus_match_queries)

        assert.has_error(function() ds.hasFocus('') end,
            'focus path must be a nonempty string')
        dfhack.gui.matchFocusString = nil
        assert.has_error(function()
            ds.hasFocus('dwarfmode/Default')
        end, 'DwarfSpec hasFocus requires dfhack.gui.matchFocusString')
    end)

    it('requires explicit unmount before mounting another component',
            function()
        local first = ds.mount(TestWidget, {name='first'})
        local first_screen = screen

        assert.has_error(function()
            ds.mount(TestWidget, {name='second'})
        end, 'DwarfSpec mount rejected because mount 1 is still current; ' ..
            'call ds.unmount() before creating another mount')
        assert.is_true(first_screen.active)
        assert.equals('first', first:raw().name)

        ds.unmount()
        local second = ds.mount(TestWidget, {name='second'})

        assert.is_false(first_screen.active)
        assert.is_true(screen.active)
        assert.equals('second', second:raw().name)
    end)

    it('rejects every second mount combination at the shared boundary',
            function()
        local cases = {
            {
                first=function() return ds.mount(TestWidget) end,
                second=function() return ds.mount(TestWidget) end,
            },
            {
                first=function() return ds.mount(TestWidget) end,
                second=function() return ds.mountNativeScreen() end,
            },
            {
                first=function() return ds.mountNativeScreen() end,
                second=function() return ds.mount(TestWidget) end,
            },
            {
                first=function() return ds.mountNativeScreen() end,
                second=function() return ds.mountNativeScreen() end,
            },
        }

        for _, case in ipairs(cases) do
            local first = case.first()
            local mount_id = run.mount_cleanup_probe().current_mount_id
            assert.has_error(case.second,
                ('DwarfSpec mount rejected because mount %d is still ' ..
                    'current; call ds.unmount() before creating another mount')
                        :format(mount_id))
            assert.is_not_nil(first:raw())
            ds.unmount()
            assert.is_nil(run.mount_cleanup_probe().current_mount_id)
        end
        assert.equals(0, native_screen.dismiss_calls)
        assert.equals(0, native_screen.navigation_calls)
    end)

    it('switches mount entry points only after explicit unmount', function()
        local component = ds.mount(TestWidget, {name='before-native'})
        assert.equals('before-native', component:raw().name)

        ds.unmount()
        local native = ds.mountNativeScreen()
        assert.equals(native_root, native:raw())
        assert.equals(1, component_mount_calls)

        ds.unmount()
        local replacement = ds.mount(TestWidget, {name='after-native'})
        assert.equals('after-native', replacement:raw().name)
        assert.equals(2, component_mount_calls)
        assert.equals(0, native_screen.dismiss_calls)
        assert.equals(0, native_screen.navigation_calls)
    end)

    it('attaches non-owningly only through the explicit native command',
            function()
        local mount_error =
            'DwarfSpec ds.mount() requires a component; use ' ..
                'ds.mountNativeScreen() to mount the current native DF screen'
        assert.has_error(function() ds.mount() end, mount_error)
        assert.has_error(function() ds.mount(nil) end, mount_error)
        assert.has_error(function()
            ds.mountNativeScreen({})
        end, 'DwarfSpec ds.mountNativeScreen() does not accept arguments')
        assert.is_nil(run.mount_cleanup_probe().current_mount_id)

        local mounted = ds.mountNativeScreen()

        assert.equals(native_root, mounted:raw())
        local root_subject = ds.root()
        assert.equals(native_root, root_subject:raw())
        ds.input('SELECT')
        assert.equals(native_screen, simulated_inputs[1].screen)
        assert.equals('SELECT', simulated_inputs[1].key)
        assert.equals(0, component_mount_calls)
        assert.equals(1, native_invalidation_count)
        assert.not_equals(original_native_render_dispatcher,
            package.loaded['plugins.overlay'].render_viewscreen_widgets)
        assert.is_nil(screen)
        assert.same({
            current_mount_id=1,
            active_screen_count=0,
            tracked_screen_count=0,
            owned_screen_count=0,
            borrowed_native_screen_count=1,
            native_attachment_count=1,
            native_screen_dismissal_count=0,
            subject_count=2,
            pointer_active=false,
            button_state_active=false,
            map_view_position_active=false,
            game_pause_state_active=false,
            game_speed_active=false,
            render_observer_active=true,
        }, run.mount_cleanup_probe())
        assert.has_error(function()
            ds.viewport(80, 25)
        end, 'DwarfSpec viewport is unavailable for a non-owning ' ..
            'native-screen mount')
        assert.same({
            show_calls=0,
            dismiss_calls=0,
            resize_calls=0,
            replace_calls=0,
            navigation_calls=0,
        }, {
            show_calls=native_screen.show_calls,
            dismiss_calls=native_screen.dismiss_calls,
            resize_calls=native_screen.resize_calls,
            replace_calls=native_screen.replace_calls,
            navigation_calls=native_screen.navigation_calls,
        })

        ds.unmount()

        assert.is_nil(run.mount_cleanup_probe().current_mount_id)
        assert.equals(0, run.mount_cleanup_probe().tracked_screen_count)
        assert.equals(0, native_screen.dismiss_calls)
        assert.has_error(function() mounted:raw() end,
            'stage=retained_subject_reacquisition ' ..
            'DwarfSpec subject raw access rejected stale subject ' ..
            'control_path="<root>" from mount 1; no current mount exists')
    end)

    it('returns copied focus strings for the current mounted subject',
            function()
        local mounted = ds.mountNativeScreen()

        assert.same({'dwarfmode/Default', 'dwarfmode/Info'},
            mounted:getFocusList())
        local focus_list = mounted:getFocusList()
        assert.same({'dwarfmode/Default', 'dwarfmode/Info'}, focus_list)
        assert.same({native_screen, native_screen}, focus_queries)

        focus_list[1] = 'mutated-by-test'
        assert.same({'dwarfmode/Default', 'dwarfmode/Info'},
            mounted:getFocusList())

        ds.unmount()
    end)

    it('waits for observed native redraw and supports explicit wait opt-out',
            function()
        local mounted = ds.mountNativeScreen()
        local baseline_waits = wait_until_calls
        local baseline_invalidations = native_invalidation_count

        ds.redraw()
        assert.equals(baseline_invalidations + 1,
            native_invalidation_count)
        assert.equals(baseline_waits + 1, wait_until_calls)

        baseline_waits = wait_until_calls
        baseline_invalidations = native_invalidation_count
        assert.equals(mounted, mounted:redraw({wait=false}))
        assert.equals(baseline_invalidations + 1,
            native_invalidation_count)
        assert.equals(baseline_waits, wait_until_calls)

        ds.unmount()
        assert.equals(original_native_render_dispatcher,
            package.loaded['plugins.overlay'].render_viewscreen_widgets)
    end)

    it('cleans native reversible state in explicit LIFO layers', function()
        local overlay_root = {
            view_id='overlay-root',
            subviews={},
            visible=true,
            active=true,
        }
        overlay_state.db['gui/example.CleanupOverlay'] = {
            widget=overlay_root,
        }
        overlay_state.config['gui/example.CleanupOverlay'] = {
            enabled=true,
        }
        local native_subject = ds.mountNativeScreen()
        local overlay_subject = ds.root({
            source=ds.ESubjectSource.OVERLAY,
            overlay='gui/example.CleanupOverlay',
        })
        ds.move_pointer(75, 68, EPointerSpace.PIXELS)
        assert.is_true(run.mount_cleanup_probe().pointer_active)
        ds.mouseInput(EMouseButton.LEFT, EInputState.DOWN)
        assert.same({7, 8}, {dfhack.screen.getMousePos()})
        assert.same({75, 68}, {dfhack.screen.getMousePixels()})
        assert.same({7, 8, 75, 68}, {
            df.global.gps.mouse_x,
            df.global.gps.mouse_y,
            df.global.gps.precise_mouse_x,
            df.global.gps.precise_mouse_y,
        })

        local names = {}
        for _, entry in ipairs(registry.entries) do
            table.insert(names, entry.name)
        end
        assert.same({
            'detach native screen 1',
            'clear native subject descriptors 1',
            'restore native render observation 1',
            'virtual pointer',
            'mouse button state',
        }, names)
        assert.equals(1, df.global.enabler.mouse_lbut_down)

        ds.unmount()

        assert.is_nil(native_subject._descriptor)
        assert.is_nil(overlay_subject._descriptor)
        assert.same({90, 91}, {dfhack.screen.getMousePos()})
        assert.same({900, 910}, {dfhack.screen.getMousePixels()})
        assert.same({4, 5, 40, 50}, {
            df.global.gps.mouse_x,
            df.global.gps.mouse_y,
            df.global.gps.precise_mouse_x,
            df.global.gps.precise_mouse_y,
        })
        assert.equals(0, df.global.enabler.mouse_lbut_down)
        assert.equals(0, df.global.enabler.mouse_lbut_lift)
        assert.is_false(df.global.enabler.mouse_focus)
        assert.equals(0, df.global.enabler.tracking_on)
        assert.equals(original_native_render_dispatcher,
            package.loaded['plugins.overlay'].render_viewscreen_widgets)
        assert.equals(0, cleanup.pending_count(registry))
        local state = run.mount_cleanup_probe()
        assert.is_nil(state.current_mount_id)
        assert.equals(0, state.owned_screen_count)
        assert.equals(0, state.tracked_screen_count)
        assert.equals(0, state.borrowed_native_screen_count)
        assert.equals(1, state.native_attachment_count)
        assert.equals(0, state.native_screen_dismissal_count)
        assert.equals(0, state.subject_count)
        assert.is_false(state.pointer_active)
        assert.is_false(state.button_state_active)
        assert.is_false(state.render_observer_active)
        assert.equals(0, native_screen.dismiss_calls)
        assert.equals(0, native_screen.navigation_calls)
    end)

    it('cleans native state after assertion, input, render, and timeout errors',
            function()
        local scenarios = {
            {
                name='assertion failure',
                fail=function()
                    error('injected assertion failure', 0)
                end,
            },
            {
                name='input error',
                prepare=function()
                    simulate_input_failure =
                        'injected terminal input failure'
                end,
                fail=function()
                    ds.input('SELECT')
                end,
            },
            {
                name='render error',
                prepare=function()
                    native_render_failure =
                        'injected terminal render failure'
                end,
                fail=function()
                    ds.redraw()
                end,
            },
            {
                name='redraw timeout',
                prepare=function()
                    suppress_native_render = true
                    wait_until_failure =
                        'injected native redraw timeout'
                end,
                fail=function()
                    ds.redraw()
                end,
            },
        }
        for _, scenario in ipairs(scenarios) do
            local retained = ds.mountNativeScreen()
            ds.move_pointer(2, 3)
            ds.mouseInput(EMouseButton.LEFT, EInputState.DOWN)
            if scenario.prepare then scenario.prepare() end

            local ok = pcall(scenario.fail)
            assert.is_false(ok, scenario.name)
            reset('after ' .. scenario.name)

            assert.is_nil(retained._descriptor, scenario.name)
            assert.equals(0, cleanup.pending_count(registry),
                scenario.name)
            assert.same({90, 91}, {dfhack.screen.getMousePos()})
            assert.same({900, 910}, {dfhack.screen.getMousePixels()})
            assert.same({4, 5, 40, 50}, {
                df.global.gps.mouse_x,
                df.global.gps.mouse_y,
                df.global.gps.precise_mouse_x,
                df.global.gps.precise_mouse_y,
            })
            assert.equals(0, df.global.enabler.mouse_lbut_down,
                scenario.name)
            assert.equals(original_native_render_dispatcher,
                package.loaded['plugins.overlay']
                    .render_viewscreen_widgets)
            local state = run.mount_cleanup_probe()
            assert.is_nil(state.current_mount_id, scenario.name)
            assert.equals(0, state.owned_screen_count, scenario.name)
            assert.equals(0, state.borrowed_native_screen_count,
                scenario.name)
            assert.equals(0, state.subject_count, scenario.name)
            assert.equals(0, state.native_screen_dismissal_count,
                scenario.name)
            assert.is_false(state.pointer_active, scenario.name)
            assert.is_false(state.button_state_active, scenario.name)
            assert.is_false(state.render_observer_active, scenario.name)
            simulate_input_failure = nil
            native_render_failure = nil
            suppress_native_render = false
            wait_until_failure = nil
        end
        assert.equals(0, native_screen.dismiss_calls)
        assert.equals(0, native_screen.navigation_calls)
    end)

    it('drains native mounts for scheduler abort and runner recovery',
            function()
        for _, reason in ipairs({
                'scheduler abort',
                'external runner recovery',
            }) do
            local retained = ds.mountNativeScreen()
            ds.move_pointer(4, 6)
            ds.mouseInput(EMouseButton.RIGHT, EInputState.DOWN)

            assert.is_true(cleanup.run(registry, reason))

            assert.is_nil(retained._descriptor, reason)
            assert.equals(0, cleanup.pending_count(registry), reason)
            assert.same({90, 91}, {dfhack.screen.getMousePos()})
            assert.same({900, 910}, {dfhack.screen.getMousePixels()})
            assert.same({4, 5, 40, 50}, {
                df.global.gps.mouse_x,
                df.global.gps.mouse_y,
                df.global.gps.precise_mouse_x,
                df.global.gps.precise_mouse_y,
            })
            assert.equals(0, df.global.enabler.mouse_rbut_down,
                reason)
            assert.equals(original_native_render_dispatcher,
                package.loaded['plugins.overlay']
                    .render_viewscreen_widgets)
            local state = run.mount_cleanup_probe()
            assert.is_nil(state.current_mount_id, reason)
            assert.equals(0, state.owned_screen_count, reason)
            assert.equals(0, state.borrowed_native_screen_count,
                reason)
            assert.equals(0, state.subject_count, reason)
            assert.is_false(state.pointer_active, reason)
            assert.is_false(state.button_state_active, reason)
            assert.is_false(state.render_observer_active, reason)
        end
        assert.equals(0, native_screen.dismiss_calls)
        assert.equals(0, native_screen.navigation_calls)
    end)

    it('does not accumulate state across repeated native attachments',
            function()
        for iteration = 1, 5 do
            local retained = ds.mountNativeScreen()
            ds.move_pointer(iteration, iteration)
            ds.mouseInput(EMouseButton.MIDDLE, EInputState.DOWN)

            ds.unmount()

            assert.is_nil(retained._descriptor)
            assert.equals(0, cleanup.pending_count(registry))
            assert.same({90, 91}, {dfhack.screen.getMousePos()})
            assert.same({900, 910}, {dfhack.screen.getMousePixels()})
            assert.same({4, 5, 40, 50}, {
                df.global.gps.mouse_x,
                df.global.gps.mouse_y,
                df.global.gps.precise_mouse_x,
                df.global.gps.precise_mouse_y,
            })
            assert.equals(0, df.global.enabler.mouse_mbut_down)
            assert.equals(original_native_render_dispatcher,
                package.loaded['plugins.overlay']
                    .render_viewscreen_widgets)
            local state = run.mount_cleanup_probe()
            assert.is_nil(state.current_mount_id)
            assert.equals(0, state.owned_screen_count)
            assert.equals(0, state.tracked_screen_count)
            assert.equals(0, state.borrowed_native_screen_count)
            assert.equals(iteration, state.native_attachment_count)
            assert.equals(0, state.native_screen_dismissal_count)
            assert.equals(0, state.subject_count)
            assert.is_false(state.pointer_active)
            assert.is_false(state.button_state_active)
            assert.is_false(state.render_observer_active)
        end
        assert.equals(0, native_screen.dismiss_calls)
        assert.equals(0, native_screen.navigation_calls)
    end)

    it('retains native subject access across a top-screen transition',
            function()
        local mounted = ds.mountNativeScreen()
        local next_screen = {
            name='next-native-screen',
            widgets={kind='next-widget-root'},
        }
        current_native_screen = next_screen

        assert.equals(native_root, mounted:raw())
        ds.input('SELECT')
        assert.equals(next_screen,
            simulated_inputs[#simulated_inputs].screen)
        assert.equals(0, native_screen.dismiss_calls)
    end)

    it('resolves native named, indexed, mixed, and slash-bearing paths',
            function()
        local slash = make_native_widget(
            'Right/panel', 'df.widget_textst')
        local row = make_native_widget(nil, 'df.widget_container', {slash})
        local tabs = make_native_widget(
            'Tabs', 'df.widget_container', {row})
        local hidden = make_native_widget(
            'Hidden', 'df.widget_textst', nil, {
                visible=false,
            })
        local inactive = make_native_widget(
            'Inactive', 'df.widget_textst', nil, {
                active=false,
            })
        native_root.children = {tabs, hidden, inactive}
        ds.mountNativeScreen()

        local named = ds.get('Tabs')
        local lookup_count = native_widget_lookup_calls
        assert.equals(tabs, named:raw())
        assert.equals(lookup_count + 1, native_widget_lookup_calls)
        assert.equals(tabs, ds.get({0}):raw())
        local mixed = ds.get({'Tabs', 0, 'Right/panel'})
        assert.equals(slash, mixed:raw())
        assert.equals(
            '{"Tabs", 0, "Right/panel"}', mixed.control_path)
        assert.equals(hidden, ds.get('Hidden'):raw())
        assert.equals(inactive, ds.get('Inactive'):raw())
    end)

    it('resolves the common complete game-UI path without source options',
            function()
        local game_ui = install_game_ui()
        ds.mountNativeScreen()

        local selected = ds.get(game_ui.path)

        assert.equals(game_ui.final_widget, selected:raw())
        assert.same(
            {'Tabs', 'Dead/Missing'},
            selected._descriptor.path_segments)
        assert.equals(
            '{"info", "creatures", "Tabs", "Dead/Missing"}',
            selected.control_path)
        assert.is_not.equal(
            ds.root()._descriptor.source,
            selected._descriptor.source)
        assert.equals(native_root, ds.root():raw())
    end)

    it('deduplicates matching viewscreen and game-UI identities',
            function()
        local game_ui = install_game_ui()
        native_root.children = {game_ui.info}
        ds.mountNativeScreen()

        local selected = ds.get(game_ui.path)

        assert.equals(game_ui.final_widget, selected:raw())
        assert.equals(
            ds.root()._descriptor.source,
            selected._descriptor.source)
        assert.same(game_ui.path, selected._descriptor.path_segments)
    end)

    it('returns the viewscreen result when eligible game-UI lookup fails',
            function()
        local game_ui = install_game_ui()
        game_ui.creatures.children = {}
        local viewscreen_final = make_native_widget(
            'Dead/Missing', 'df.widget_text', nil, {
                str='Viewscreen result',
            })
        local viewscreen_tabs = make_native_widget(
            'Tabs', 'df.widget_container', {viewscreen_final})
        local viewscreen_creatures = make_native_widget(
            'creatures', 'df.widget_container', {viewscreen_tabs})
        local viewscreen_info = make_native_widget(
            'info', 'df.widget_container', {viewscreen_creatures})
        native_root.children = {viewscreen_info}
        ds.mountNativeScreen()

        local selected = ds.get(game_ui.path)

        assert.equals(viewscreen_final, selected:raw())
        assert.equals('Viewscreen result', selected:text())
        assert.same(
            game_ui.path, selected._descriptor.path_segments)
    end)

    it('rejects different viewscreen and game-UI identities as ambiguous',
            function()
        local game_ui = install_game_ui()
        local viewscreen_final = make_native_widget(
            'Dead/Missing', 'df.widget_text', nil, {
                str='Different viewscreen result',
            })
        local viewscreen_tabs = make_native_widget(
            'Tabs', 'df.widget_container', {viewscreen_final})
        local viewscreen_creatures = make_native_widget(
            'creatures', 'df.widget_container', {viewscreen_tabs})
        local viewscreen_info = make_native_widget(
            'info', 'df.widget_container', {viewscreen_creatures})
        native_root.children = {viewscreen_info}
        ds.mountNativeScreen()

        local ok, failure = pcall(ds.get, game_ui.path)

        assert.is_false(ok)
        assert.matches(
            'native_path={"info", "creatures", "Tabs", "Dead/Missing"}',
            failure, 1, true)
        assert.matches('is ambiguous;', failure, 1, true)
        assert.matches('stage=ambiguity_check', failure, 1, true)
        assert.matches(
            'viewscreen={root_type="df.widget_container" ' ..
                'root_identity=table#%d+ widget_type="df.widget_text" ' ..
                'widget_identity=table#%d+}',
            failure)
        assert.matches(
            'game_ui={root_type="df.widget_container" ' ..
                'root_identity=table#%d+ widget_type="df.widget_text" ' ..
                'widget_identity=table#%d+}',
            failure)
        assert.is_true(#failure < 8192)
    end)

    it('reports both unavailable roots with the complete original path',
            function()
        local game_ui = install_game_ui()
        game_ui.creatures.children = {}
        ds.mountNativeScreen()

        local ok, failure = pcall(ds.get, game_ui.path)

        assert.is_false(ok)
        assert.matches(
            'native_path={"info", "creatures", "Tabs", "Dead/Missing"}',
            failure, 1, true)
        assert.matches(
            'was unavailable from both native roots',
            failure, 1, true)
        assert.matches('viewscreen={', failure, 1, true)
        assert.matches('stage=ambiguity_check', failure, 1, true)
        assert.matches(
            'game_ui={stage=widget_traversal', failure, 1, true)
        assert.matches(
            'structural_prefix={"info", "creatures"}',
            failure, 1, true)
        assert.matches(
            'widget_suffix={"Tabs", "Dead/Missing"}',
            failure, 1, true)
        assert.matches('kind=missing_widget', failure, 1, true)
    end)

    it('does not enter unrelated game interfaces after a native miss',
            function()
        local mutation_calls = 0
        local main_interface = {
            _type={_name='df.main_interface', _fields={
                unrelated={
                    name='unrelated',
                    mode=EFieldMode.SUBSTRUCT,
                },
            }},
            unrelated=setmetatable({}, {
                __index=function()
                    mutation_calls = mutation_calls + 1
                    error('unrelated interface was inspected')
                end,
            }),
        }
        df.global.game = {main_interface=main_interface}
        df.widget = {
            is_instance=function() return false end,
        }
        df.widget_container = {
            is_instance=function() return false end,
        }
        ds.mountNativeScreen()

        local ok, failure = pcall(ds.get, 'Missing')

        assert.is_false(ok)
        assert.matches(
            'native_path={"Missing"}', failure, 1, true)
        assert.is_nil(failure:find(
            'both native roots', 1, true))
        assert.equals(0, mutation_calls)
    end)

    it('routes game-UI subjects through native inspection and interaction',
            function()
        local game_ui = install_game_ui()
        ds.mountNativeScreen()
        local selected = ds.get(game_ui.path)
        local baseline_invalidations = native_invalidation_count

        local inspection = ds.inspect(selected)
        local text = selected:text()
        selected:move_pointer('center')
        local pointer_position = {dfhack.screen.getMousePos()}
        selected:input('GAME_UI_INPUT')
        ds.mouseInput(EMouseButton.LEFT, EInputState.CLICK)
        selected:redraw()
        local tree = ds.capture_view_tree('game-ui-tree', {
            native_root=game_ui.creatures,
        })

        assert.equals('Deceased citizens', inspection.text)
        assert.equals('Deceased citizens', text)
        assert.same(
            {x1=10, y1=5, x2=24, y2=7}, inspection.body)
        assert.equals('Tabs', tree.children[1].view_id)
        assert.equals(tree, run.captures['game-ui-tree'])
        assert.same({17, 6}, pointer_position)
        assert.equals('GAME_UI_INPUT',
            simulated_inputs[#simulated_inputs - 1].key)
        assert.equals('_MOUSE_L',
            simulated_inputs[#simulated_inputs].key)
        assert.equals(native_screen,
            simulated_inputs[#simulated_inputs].screen)
        assert.equals(
            baseline_invalidations + 1,
            native_invalidation_count)
    end)

    it('resolves exposed base-game controls from an explicit native root',
            function()
        local row = make_native_widget(
            nil, 'df.widget_container', {
                make_native_widget(
                    'Label', 'df.widget_text', nil, {str='Route 1'}),
            })
        local rows = make_native_widget(
            'Rows', 'df.widget_container', {row})
        local main_interface_root = make_native_widget(
            nil, 'df.widget_container', {rows})
        ds.mountNativeScreen()

        local options = {native_root=main_interface_root}
        local selected_root = ds.root(options)
        local selected_row = ds.get({'Rows', 0}, options)
        local selected_label = ds.get({'Rows', 0, 'Label'}, options)
        local tree = ds.capture_view_tree('main-interface', options)

        assert.equals(main_interface_root, selected_root:raw())
        assert.equals(row, selected_row:raw())
        assert.equals('Route 1', selected_label:text())
        assert.equals('Rows', tree.children[1].view_id)
        assert.equals(selected_root._descriptor.source,
            selected_row._descriptor.source)
        assert.equals(selected_row._descriptor.source,
            selected_label._descriptor.source)
        assert.equals(native_root, ds.root():raw())
    end)

    it('keeps explicit native roots isolated from automatic game-UI lookup',
            function()
        local game_ui = install_game_ui()
        local explicit_final = make_native_widget(
            'Dead/Missing', 'df.widget_text', nil, {
                str='Explicit result',
            })
        local explicit_tabs = make_native_widget(
            'Tabs', 'df.widget_container', {explicit_final})
        local explicit_creatures = make_native_widget(
            'creatures', 'df.widget_container', {explicit_tabs})
        local explicit_info = make_native_widget(
            'info', 'df.widget_container', {explicit_creatures})
        local explicit_root = make_native_widget(
            nil, 'df.widget_container', {explicit_info})
        ds.mountNativeScreen()

        local selected = ds.get(
            game_ui.path, {native_root=explicit_root})

        assert.equals(explicit_final, selected:raw())
        assert.is_not.equal(game_ui.final_widget, selected:raw())
    end)

    it('keeps overlay and component paths outside game-UI resolution',
            function()
        install_game_ui()
        local overlay_final = {
            view_id='Dead',
            subviews={},
            visible=true,
            active=true,
        }
        local overlay_root = {
            view_id='overlay-root',
            subviews={{
                view_id='info',
                subviews={{view_id='creatures', subviews={{
                    view_id='Tabs',
                    subviews={overlay_final},
                }}}},
            }},
            visible=true,
            active=true,
        }
        overlay_state.db['gui/example.GameUIOverlay'] = {
            widget=overlay_root,
        }
        overlay_state.config['gui/example.GameUIOverlay'] = {enabled=true}
        ds.mountNativeScreen()
        local overlay = ds.get('info/creatures/Tabs/Dead', {
            source=ds.ESubjectSource.OVERLAY,
            overlay='gui/example.GameUIOverlay',
        })
        assert.equals(overlay_final, overlay:raw())
        ds.unmount()

        local component_child = {
            view_id='info',
            subviews={},
        }
        ds.mount(TestWidget, {
            name='component',
            subviews={component_child},
        })
        local component_subject = ds.get('info')

        assert.equals(component_child, component_subject:raw())
        assert.equals(1, component_mount_calls)
    end)

    it('rejects a native root that is not an exposed widget container',
            function()
        ds.mountNativeScreen()

        assert.has_error(function()
            ds.get('Rows', {native_root={}})
        end, 'native_root must be a DF widget_container exposed by DFHack')
    end)

    it('keeps default native and explicit overlay path collisions separate',
            function()
        local native_shared = make_native_widget(
            'Shared', 'df.widget_text', nil, {
                flag={
                    VISIBILITY_VISIBLE=true,
                    VISIBILITY_ACTIVE=true,
                },
            })
        native_root.children = {native_shared}
        local overlay_shared = {
            view_id='Shared',
            subviews={},
            visible=true,
            active=true,
            text='overlay',
        }
        local overlay_root = {
            view_id='overlay-root',
            subviews={overlay_shared},
            visible=true,
            active=true,
        }
        overlay_state.db['gui/example.ExampleOverlay'] = {
            widget=overlay_root,
        }
        overlay_state.config['gui/example.ExampleOverlay'] = {enabled=true}
        ds.mountNativeScreen()

        local native = ds.get('Shared')
        local options = {
            source=ds.ESubjectSource.OVERLAY,
            overlay='gui/example.ExampleOverlay',
        }
        local overlay = ds.get('Shared', options)
        local selected_root = ds.root(options)

        assert.equals(native_shared, native:raw())
        assert.equals(overlay_shared, overlay:raw())
        assert.equals(overlay_root, selected_root:raw())
        assert.equals(ds.ESubjectSource.NATIVE,
            native._descriptor.source.kind)
        assert.equals(ds.ESubjectSource.OVERLAY,
            overlay._descriptor.source.kind)
        assert.equals(native_root, ds.root():raw())
    end)

    it('rejects missing and disabled explicit overlay selections', function()
        ds.mountNativeScreen()
        local options = {
            source=ds.ESubjectSource.OVERLAY,
            overlay='gui/example.Missing',
        }
        assert.has_error(function() ds.root(options) end,
            'DwarfSpec overlay subject selection could not find exact ' ..
                'registry name="gui/example.Missing"')

        overlay_state.db['gui/example.Disabled'] = {
            widget={view_id='disabled', subviews={}},
        }
        overlay_state.config['gui/example.Disabled'] = {enabled=false}
        options.overlay = 'gui/example.Disabled'
        assert.has_error(function() ds.root(options) end,
            'DwarfSpec overlay subject selection requires enabled registry ' ..
                'name="gui/example.Disabled"')
    end)

    it('makes retained overlay subjects stale across a rescan replacement',
            function()
        local original = {
            view_id='overlay-root',
            subviews={},
            visible=true,
            active=true,
        }
        overlay_state.db['gui/example.ExampleOverlay'] = {widget=original}
        overlay_state.config['gui/example.ExampleOverlay'] = {enabled=true}
        ds.mountNativeScreen()
        local options = {
            source=ds.ESubjectSource.OVERLAY,
            overlay='gui/example.ExampleOverlay',
        }
        local retained = ds.root(options)
        local replacement = {
            view_id='overlay-root',
            subviews={},
            visible=true,
            active=true,
        }
        overlay_state.db['gui/example.ExampleOverlay'] = {
            widget=replacement,
        }

        local ok, failure = pcall(retained.raw, retained)
        assert.is_false(ok)
        assert.matches('stale overlay subject registry name=' ..
            '"gui/example.ExampleOverlay" was replaced', failure, 1, true)
        assert.equals(replacement, ds.root(options):raw())
    end)

    it('captures native and overlay trees from separate source roots',
            function()
        native_root.children = {
            make_native_widget(
                'NativeOnly', 'df.widget_text', nil, {
                    flag={
                        VISIBILITY_VISIBLE=true,
                        VISIBILITY_ACTIVE=true,
                    },
                }),
        }
        local overlay_root = {
            view_id='overlay-root',
            subviews={{
                view_id='OverlayOnly',
                subviews={},
                visible=true,
                active=true,
            }},
            visible=true,
            active=true,
        }
        overlay_state.db['gui/example.ExampleOverlay'] = {
            widget=overlay_root,
        }
        overlay_state.config['gui/example.ExampleOverlay'] = {enabled=true}
        ds.mountNativeScreen()

        local native_tree = ds.capture_view_tree('native-tree')
        local overlay_tree = ds.capture_view_tree('overlay-tree', {
            source=ds.ESubjectSource.OVERLAY,
            overlay='gui/example.ExampleOverlay',
        })

        assert.equals('NativeOnly', native_tree.children[1].view_id)
        assert.equals('OverlayOnly', overlay_tree.children[1].view_id)
        assert.equals('overlay-root', overlay_tree.view_id)
        assert.equals(native_tree, run.captures['native-tree'])
        assert.equals(overlay_tree, run.captures['overlay-tree'])
    end)

    it('leaves overlay registry lifecycle and configuration externally owned',
            function()
        local lifecycle_calls = 0
        local overlay_root = {
            view_id='overlay-root',
            subviews={},
            visible=true,
            active=true,
            overlay_onenable=function()
                lifecycle_calls = lifecycle_calls + 1
            end,
            overlay_ondisable=function()
                lifecycle_calls = lifecycle_calls + 1
            end,
        }
        local entry = {widget=overlay_root}
        local config = {enabled=true, x=7, y=9}
        overlay_state.db['gui/example.ExampleOverlay'] = entry
        overlay_state.config['gui/example.ExampleOverlay'] = config
        ds.mountNativeScreen()
        local selected = ds.root({
            source=ds.ESubjectSource.OVERLAY,
            overlay='gui/example.ExampleOverlay',
        })

        selected:inspect()
        ds.unmount()

        assert.equals(0, lifecycle_calls)
        assert.equals(entry,
            overlay_state.db['gui/example.ExampleOverlay'])
        assert.equals(config,
            overlay_state.config['gui/example.ExampleOverlay'])
        assert.same({enabled=true, x=7, y=9}, config)
    end)

    it('uses clipped native bounds and rejects unusable pointer subjects',
            function()
        local partial = make_native_widget(
            'Partial', 'df.widget', nil, {
                rect={x1=-3, y1=4, x2=6, y2=10},
                flag={
                    VISIBILITY_VISIBLE=true,
                    VISIBILITY_ACTIVE=true,
                },
            })
        local invalid = make_native_widget(
            'Invalid', 'df.widget', nil, {
                rect={x1=7, y1=9, x2=3, y2=11},
                flag={
                    VISIBILITY_VISIBLE=true,
                    VISIBILITY_ACTIVE=true,
                },
            })
        local offscreen = make_native_widget(
            'Offscreen', 'df.widget', nil, {
                rect={x1=90, y1=30, x2=100, y2=40},
                flag={
                    VISIBILITY_VISIBLE=true,
                    VISIBILITY_ACTIVE=true,
                },
            })
        native_root.children = {partial, invalid, offscreen}
        ds.mountNativeScreen()

        assert.same({0, 4}, {
            ds.move_pointer(ds.get('Partial'), 'top_left'),
        })
        assert.has_error(function()
            ds.move_pointer(ds.get('Invalid'))
        end, 'DwarfSpec pointer placement failed: source="native" ' ..
            'path="{\\"Invalid\\"}" native_type="df.widget" ' ..
            'bounds=<unavailable> reason="no usable live bounds within the ' ..
                'current window"')
        assert.has_error(function()
            ds.move_pointer(ds.get('Offscreen'))
        end, 'DwarfSpec pointer placement failed: source="native" ' ..
            'path="{\\"Offscreen\\"}" native_type="df.widget" ' ..
            'bounds={x1=90,y1=30,x2=100,y2=40} reason="no usable live ' ..
                'bounds within the current window"')
        assert.same({x1=90, y1=30, x2=100, y2=40},
            ds.get('Offscreen'):inspect().body)
    end)

    it('supports default grid, explicit grid, pixels, hover, and repeats',
            function()
        ds.mountNativeScreen()

        assert.same({0, 0}, {ds.move_pointer(0, 0)})
        assert.same({0, 0}, {dfhack.screen.getMousePos()})
        assert.same({5, 4}, {dfhack.screen.getMousePixels()})

        assert.same({79, 24}, {
            ds.move_pointer(79, 24, EPointerSpace.GRID),
        })
        assert.same({79, 24}, {dfhack.screen.getMousePos()})
        assert.same({795, 196}, {dfhack.screen.getMousePixels()})

        assert.same({126, 93}, {
            ds.move_pointer(126, 93, EPointerSpace.PIXELS),
        })
        assert.same({12, 11}, {dfhack.screen.getMousePos()})
        assert.same({126, 93}, {dfhack.screen.getMousePixels()})
        assert.same({12, 11, 126, 93}, {
            df.global.gps.mouse_x,
            df.global.gps.mouse_y,
            df.global.gps.precise_mouse_x,
            df.global.gps.precise_mouse_y,
        })
        df.global.gps.mouse_x = -1
        df.global.gps.mouse_y = -1
        df.global.gps.precise_mouse_x = -1
        df.global.gps.precise_mouse_y = -1
        ds.mouseInput(EMouseButton.SCROLL_DOWN)
        assert.same({12, 11, 126, 93}, {
            simulated_inputs[1].x,
            simulated_inputs[1].y,
            simulated_inputs[1].pixel_x,
            simulated_inputs[1].pixel_y,
        })

        assert.same({799, 199}, {
            ds.hover(799, 199, EPointerSpace.PIXELS),
        })
        assert.same({79, 24}, {dfhack.screen.getMousePos()})
        assert.same({799, 199}, {dfhack.screen.getMousePixels()})
        local pointer_entries = 0
        for _, entry in ipairs(registry.entries) do
            if entry.name == 'virtual pointer' then
                pointer_entries = pointer_entries + 1
            end
        end
        assert.equals(1, pointer_entries)
    end)

    it('reapplies paired raw coordinates after each render wait', function()
        ds.mountNativeScreen()
        wait_until_dispatch = function()
            df.global.gps.mouse_x = -1
            df.global.gps.mouse_y = -1
            df.global.gps.precise_mouse_x = -1
            df.global.gps.precise_mouse_y = -1
        end

        ds.move_pointer(2, 3)
        assert.same({2, 3, 25, 28}, {
            df.global.gps.mouse_x,
            df.global.gps.mouse_y,
            df.global.gps.precise_mouse_x,
            df.global.gps.precise_mouse_y,
        })

        ds.mouseInput(EMouseButton.SCROLL_DOWN)
        assert.same({2, 3, 25, 28}, {
            simulated_inputs[1].x,
            simulated_inputs[1].y,
            simulated_inputs[1].pixel_x,
            simulated_inputs[1].pixel_y,
        })
        assert.same({2, 3, 25, 28}, {
            df.global.gps.mouse_x,
            df.global.gps.mouse_y,
            df.global.gps.precise_mouse_x,
            df.global.gps.precise_mouse_y,
        })
    end)

    it('repairs paired raw coordinates before a later map-pointer read',
            function()
        ds.mountNativeScreen()
        local sampled_position
        local sampled_result
        wait_until_dispatch = function()
            df.global.gps.mouse_x = -1
            df.global.gps.mouse_y = -1
            df.global.gps.precise_mouse_x = -1
            df.global.gps.precise_mouse_y = -1
            sampled_position, sampled_result =
                dfhack.gui.getMousePos(true)
        end

        ds.move_pointer(482, 102, EPointerSpace.PIXELS)

        assert.same({x=482, y=102, z=1}, sampled_position)
        assert.equals('native-map-result', sampled_result)
        assert.same({48, 12, 482, 102}, {
            df.global.gps.mouse_x,
            df.global.gps.mouse_y,
            df.global.gps.precise_mouse_x,
            df.global.gps.precise_mouse_y,
        })
    end)

    it('reads fresh effective geometry for every numeric pointer move',
            function()
        ds.mountNativeScreen()

        ds.move_pointer(2, 3, EPointerSpace.GRID)
        assert.same({25, 28}, {dfhack.screen.getMousePixels()})

        df.global.gps.tile_pixel_x = 6
        df.global.gps.tile_pixel_y = 4
        df.global.gps.screen_pixel_x = 480
        df.global.gps.screen_pixel_y = 100
        ds.move_pointer(2, 3, EPointerSpace.GRID)

        assert.same({2, 3}, {dfhack.screen.getMousePos()})
        assert.same({15, 14}, {dfhack.screen.getMousePixels()})

        df.global.gps.screen_pixel_x = 483
        df.global.gps.screen_pixel_y = 103
        ds.move_pointer(482, 102, EPointerSpace.PIXELS)

        assert.same({79, 24}, {dfhack.screen.getMousePos()})
        assert.same({482, 102}, {dfhack.screen.getMousePixels()})
    end)

    it('moves to world tiles and recenters the map view by default',
            function()
        ds.mountNativeScreen()

        assert.same({40, 50, 5}, {
            ds.move_pointer(
                {x=40, y=50, z=5}, EPointerSpace.WORLD_TILE)
        })

        assert.same({x=35, y=47, z=5}, map_view_position)
        assert.same({5, 3}, {dfhack.screen.getMousePos()})
        assert.same({55, 28}, {dfhack.screen.getMousePixels()})

        assert.is_true(cleanup.run(registry, 'world-tile pointer test'))
        assert.same({x=12, y=34, z=5}, map_view_position)
        assert.same({90, 91}, {dfhack.screen.getMousePos()})
        assert.same({900, 910}, {dfhack.screen.getMousePixels()})
    end)

    it('moves to an already visible world tile without recentering',
            function()
        ds.mountNativeScreen()

        assert.same({14, 36, 5}, {
            ds.move_pointer({x=14, y=36, z=5},
                EPointerSpace.WORLD_TILE, {recenter=false})
        })

        assert.same({x=12, y=34, z=5}, map_view_position)
        assert.same({2, 2}, {dfhack.screen.getMousePos()})
        assert.same({25, 20}, {dfhack.screen.getMousePixels()})
    end)

    it('uses Premium map pixels for world-tile pointer movement', function()
        ds.mountNativeScreen()
        dfhack.screen.inGraphicsMode = function() return true end
        df.global.gps.viewport_zoom_factor = 32

        ds.move_pointer(
            {x=40, y=50, z=5}, EPointerSpace.WORLD_TILE)

        assert.same({4, 3}, {dfhack.screen.getMousePos()})
        assert.same({44, 28}, {dfhack.screen.getMousePixels()})
    end)

    it('rejects invalid or invisible world-tile pointer requests',
            function()
        ds.mountNativeScreen()
        local cases = {
            {
                invoke=function()
                    ds.move_pointer({x=-1, y=36, z=5},
                        EPointerSpace.WORLD_TILE)
                end,
                expected='world-tile x coordinate must be a nonnegative integer',
            },
            {
                invoke=function()
                    ds.move_pointer({x=14, y=36},
                        EPointerSpace.WORLD_TILE)
                end,
                expected='world-tile z coordinate must be a nonnegative integer',
            },
            {
                invoke=function()
                    ds.move_pointer({x=14, y=36, z=5},
                        EPointerSpace.WORLD_TILE, 'bad')
                end,
                expected='world-tile pointer options must be a table',
            },
            {
                invoke=function()
                    ds.move_pointer({x=14, y=36, z=5},
                        EPointerSpace.WORLD_TILE, {recenter='yes'})
                end,
                expected='world-tile pointer recenter option must be a boolean',
            },
        }
        for _, case in ipairs(cases) do
            assert.has_error(case.invoke, case.expected)
        end
        local invisible_cases = {
            {
                position={x=14, y=36, z=6},
                expected='world tile z coordinate 6 is not on the visible ' ..
                    'z-level 5',
            },
            {
                position={x=100, y=100, z=5},
                expected='world tile (100, 100, 5) is outside the current ' ..
                    'map view',
            },
        }
        for _, case in ipairs(invisible_cases) do
            local ok, failure = pcall(ds.move_pointer, case.position,
                EPointerSpace.WORLD_TILE, {recenter=false})
            assert.is_false(ok)
            assert.matches(case.expected, failure, 1, true)
        end
    end)

    it('rejects invalid arbitrary pointer coordinates explicitly', function()
        ds.mountNativeScreen()
        local cases = {
            {
                invoke=function() ds.move_pointer(-1, 0) end,
                expected='pointer x coordinate must be a nonnegative integer',
            },
            {
                invoke=function() ds.move_pointer(0.5, 0) end,
                expected='pointer x coordinate must be a nonnegative integer',
            },
            {
                invoke=function() ds.move_pointer(0, -1) end,
                expected='pointer y coordinate must be a nonnegative integer',
            },
            {
                invoke=function() ds.move_pointer(0, 0.5) end,
                expected='pointer y coordinate must be a nonnegative integer',
            },
            {
                invoke=function() ds.move_pointer(0, nil) end,
                expected='pointer y coordinate must be a nonnegative integer',
            },
            {
                invoke=function() ds.move_pointer(80, 0) end,
                expected='pointer x coordinate 80 is outside the current ' ..
                    'window width 80',
            },
            {
                invoke=function() ds.move_pointer(0, 25) end,
                expected='pointer y coordinate 25 is outside the current ' ..
                    'window height 25',
            },
            {
                invoke=function()
                    ds.move_pointer(80, 0, EPointerSpace.GRID)
                end,
                expected='pointer x coordinate 80 is outside the current ' ..
                    'window width 80',
            },
        }
        for _, case in ipairs(cases) do
            assert.has_error(case.invoke, case.expected)
        end
    end)

    it('rejects invalid pixel coordinates and pointer spaces explicitly',
            function()
        ds.mountNativeScreen()
        local cases = {
            {
                invoke=function()
                    ds.move_pointer('bad', 0, EPointerSpace.PIXELS)
                end,
                expected='pixels x coordinate must be an integer; got bad',
            },
            {
                invoke=function()
                    ds.move_pointer(0, nil, EPointerSpace.PIXELS)
                end,
                expected='pixels y coordinate must be an integer; got nil',
            },
            {
                invoke=function()
                    ds.move_pointer(0, 'bad', EPointerSpace.PIXELS)
                end,
                expected='pixels y coordinate must be an integer; got bad',
            },
            {
                invoke=function()
                    ds.move_pointer(-1, 0, EPointerSpace.PIXELS)
                end,
                expected='pixels x coordinate -1 is outside [0, 799]',
            },
            {
                invoke=function()
                    ds.move_pointer(0, -1, EPointerSpace.PIXELS)
                end,
                expected='pixels y coordinate -1 is outside [0, 199]',
            },
            {
                invoke=function()
                    ds.move_pointer(0.5, 0, EPointerSpace.PIXELS)
                end,
                expected='pixels x coordinate must be an integer; got 0.5',
            },
            {
                invoke=function()
                    ds.move_pointer(800, 0, EPointerSpace.PIXELS)
                end,
                expected='pixels x coordinate 800 is outside [0, 799]',
            },
            {
                invoke=function()
                    ds.move_pointer(0, 200, EPointerSpace.PIXELS)
                end,
                expected='pixels y coordinate 200 is outside [0, 199]',
            },
            {
                invoke=function() ds.move_pointer(0, 0, 'pixels') end,
                expected='unsupported pointer coordinate space: pixels',
            },
            {
                invoke=function() ds.move_pointer(0, 0, 3) end,
                expected='unsupported pointer coordinate space: 3',
            },
        }
        for _, case in ipairs(cases) do
            assert.has_error(case.invoke, case.expected)
        end
    end)

    it('places the pointer at every subject anchor', function()
        local target = make_native_widget(
            'Target', 'df.widget', nil, {
                rect={x1=10, y1=12, x2=14, y2=18},
                flag={
                    VISIBILITY_VISIBLE=true,
                    VISIBILITY_ACTIVE=true,
                },
            })
        native_root.children = {target}
        ds.mountNativeScreen()
        local subject = ds.get('Target')
        local expected = {
            [EPointerAnchor.CENTER]={12, 15},
            [EPointerAnchor.TOP_LEFT]={10, 12},
            [EPointerAnchor.TOP_RIGHT]={14, 12},
            [EPointerAnchor.BOTTOM_LEFT]={10, 18},
            [EPointerAnchor.BOTTOM_RIGHT]={14, 18},
        }

        for anchor, coordinates in pairs(expected) do
            assert.same(coordinates, {ds.move_pointer(subject, anchor)})
            assert.same(coordinates, {dfhack.screen.getMousePos()})
            assert.same({
                coordinates[1] * 10 + 5,
                coordinates[2] * 8 + 4,
            }, {dfhack.screen.getMousePixels()})
        end
        assert.has_error(function()
            ds.move_pointer(subject, 'center', EPointerSpace.GRID)
        end, 'pointer coordinate space is only valid with numeric coordinates')
        assert.has_error(function()
            subject:move_pointer('center', EPointerSpace.GRID)
        end, 'subject pointer commands use UI-grid coordinates and do not ' ..
            'accept a pointer space')
        assert.has_error(function()
            subject:hover('center', EPointerSpace.PIXELS)
        end, 'subject pointer commands use UI-grid coordinates and do not ' ..
            'accept a pointer space')
    end)

    it('makes a retained native subject stale after removal', function()
        local original = make_native_widget(
            'Status', 'df.widget_textst')
        native_root.children = {original}
        ds.mountNativeScreen()
        local selected = ds.get('Status')
        native_root.children = {}

        local ok, failure = pcall(selected.raw, selected)
        assert.is_false(ok)
        assert.matches('DwarfSpec subject raw access rejected stale native ' ..
            'subject ' ..
            'path={"Status"} mount=1 because the widget no longer resolves; ' ..
                'call ds.get(path) to select it again', failure, 1, true)
        assert.matches('mount_kind="native" source="native" ' ..
            'captured_identity=table#%d+ current_identity=<nil>', failure)
        assert.is_true(#failure < 8192)
    end)

    it('requires a new native subject after same-path replacement', function()
        local original = make_native_widget(
            'Status', 'df.widget_textst')
        native_root.children = {original}
        ds.mountNativeScreen()
        local selected = ds.get('Status')
        local replacement = make_native_widget(
            'Status', 'df.widget_textst')
        native_root.children = {replacement}

        local ok, failure = pcall(selected.raw, selected)
        assert.is_false(ok)
        assert.matches('DwarfSpec subject raw access rejected stale native ' ..
            'subject ' ..
            'path={"Status"} mount=1 because the widget was replaced; call ' ..
                'ds.get(path) to select the replacement',
            failure, 1, true)
        assert.matches(
            'stage=retained_subject_reacquisition',
            failure, 1, true)
        assert.is_true(#failure < 8192)
        assert.matches('mount_kind="native" source="native" ' ..
            'captured_identity=table#%d+ current_identity=table#%d+',
            failure)
        assert.equals(replacement, ds.get('Status'):raw())
    end)

    it('reports bounded native child diagnostics for missing paths',
            function()
        for index = 0, 14 do
            table.insert(native_root.children, make_native_widget(
                ('Child%02d'):format(index), 'df.widget_textst'))
        end
        ds.mountNativeScreen()

        local ok, failure = pcall(ds.get, 'Missing')

        assert.is_false(ok)
        assert.matches('native_path={"Missing"}', failure, 1, true)
        assert.matches('missing segment%[1%]="Missing"', failure)
        assert.matches('parent_name="<native%-root>"', failure)
        assert.matches('parent_type="df.widget_container"',
            failure, 1, true)
        assert.matches('named children=%[', failure)
        assert.matches('indexed children=%[', failure)
        assert.matches('%.%.%. %(%+3 more%)', failure)
    end)

    it('reports missing control paths with current mount identity',
            function()
        ds.mount(TestWidget, {
            name='selection-errors',
            subviews={},
        })

        local missing_ok, missing = pcall(ds.get, 'missing')

        assert.is_false(missing_ok)
        assert.matches('operation="get" mount=1', missing, 1, true)
        assert.matches('selected_control_path="missing" selected_mount=1',
            missing, 1, true)
        assert.matches('control_path="missing" mount=1 missing segment="missing"',
            missing, 1, true)
    end)

    it('rejects duplicate direct child IDs while mounting', function()
        local first = {view_id='duplicate', subviews={}}
        local second = {view_id='duplicate', subviews={}}

        local mounted, failure = pcall(ds.mount, TestWidget,
            {subviews={first, second}})
        assert.is_false(mounted)
        assert.matches('DwarfSpec invalid component tree: parent ' ..
            'control_path="<root>" has multiple direct children with ' ..
            'view_id="duplicate"', failure, 1, true)
    end)

    it('reports public commands clearly without a current mount', function()
        local suffix = ' requires a current mount; call ' ..
            'ds.mount(component, options) or ds.mountNativeScreen() first'
        assert.has_error(function() ds.root() end,
            'DwarfSpec root' .. suffix)
        assert.has_error(function() ds.get('missing') end,
            'DwarfSpec get' .. suffix)
        assert.has_error(function() ds.unmount() end,
            'DwarfSpec unmount' .. suffix)
        assert.has_error(function() ds.inspect() end,
            'DwarfSpec inspect' .. suffix)
        assert.has_error(function() ds.redraw() end,
            'DwarfSpec redraw' .. suffix)
        assert.has_error(function() ds.move_pointer() end,
            'DwarfSpec move_pointer' .. suffix)
        assert.has_error(function() ds.input('SELECT') end,
            'DwarfSpec input' .. suffix)
        assert.has_error(function()
            ds.mouseInput(EMouseButton.LEFT, EInputState.CLICK)
        end, 'DwarfSpec mouseInput' .. suffix)
        assert.has_error(function() ds.click() end,
            'DwarfSpec click' .. suffix)
        assert.has_error(function() ds.type('text') end,
            'DwarfSpec type' .. suffix)
    end)

    it('sets and restores screen-anchored map-view positions without a mount',
            function()
        assert.same({x=40, y=50, z=6},
            ds.setViewPos({x=40, y=50, z=6}))
        assert.same({x=35, y=47, z=6}, map_view_position)
        assert.same({x=40, y=50, z=6}, ds.getViewPos())
        assert.is_true(run.mount_cleanup_probe().map_view_position_active)

        assert.same({x=41, y=52, z=7},
            ds.setViewPos({x=41, y=52, z=7}, EScreenOrigin.TOP_LEFT))
        assert.same({x=41, y=52, z=7}, map_view_position)
        assert.same({x=41, y=52, z=7},
            ds.getViewPos(EScreenOrigin.TOP_LEFT))
        assert.equals(1, cleanup.pending_count(registry))

        reset('map-view position example cleanup')

        assert.same({x=12, y=34, z=5}, map_view_position)
        assert.is_false(run.mount_cleanup_probe().map_view_position_active)
        assert.equals(0, cleanup.pending_count(registry))
    end)

    it('gets every map-view screen origin with DFHack-compatible offsets',
            function()
        local expected = {
            [EScreenOrigin.TOP_LEFT]={x=12, y=34, z=5},
            [EScreenOrigin.TOP]={x=17, y=34, z=5},
            [EScreenOrigin.TOP_RIGHT]={x=21, y=34, z=5},
            [EScreenOrigin.LEFT]={x=12, y=37, z=5},
            [EScreenOrigin.CENTER]={x=17, y=37, z=5},
            [EScreenOrigin.RIGHT]={x=21, y=37, z=5},
            [EScreenOrigin.BOTTOM_LEFT]={x=12, y=40, z=5},
            [EScreenOrigin.BOTTOM]={x=17, y=40, z=5},
            [EScreenOrigin.BOTTOM_RIGHT]={x=21, y=40, z=5},
        }

        for origin, position in pairs(expected) do
            assert.same(position, ds.getViewPos(origin))
        end
        assert.same(expected[EScreenOrigin.CENTER], ds.getViewPos())
        assert.equals(0, cleanup.pending_count(registry))
    end)

    it('preserves negative raw origins when anchoring an edge map tile',
            function()
        local target = {x=1, y=2, z=3}

        assert.same(target, ds.setViewPos(target, EScreenOrigin.CENTER))
        assert.same({x=-4, y=-1, z=3}, map_view_position)
        assert.same(target, ds.getViewPos(EScreenOrigin.CENTER))
        assert.same(target, ds.getViewPos())
        assert.same({x=-4, y=-1, z=3},
            ds.getViewPos(EScreenOrigin.TOP_LEFT))

        reset('edge map-view position example cleanup')
        assert.same({x=12, y=34, z=5}, map_view_position)
    end)

    it('gets a copied current map-view position without scheduling cleanup',
            function()
        local position = ds.getViewPos()

        assert.same({x=17, y=37, z=5}, position)
        position.x = 99
        assert.same({x=17, y=37, z=5}, ds.getViewPos())
        assert.equals(0, cleanup.pending_count(registry))
        assert.is_false(run.mount_cleanup_probe().map_view_position_active)

        map_view_get_failure = 'injected map-view getter failure'
        assert.has_error(function() ds.getViewPos() end,
            'DwarfSpec could not query the current map-view position: ' ..
                'injected map-view getter failure')
    end)

    it('validates map-view coordinates and restores after setter failures',
            function()
        for _, case in ipairs({
                {
                    position=nil,
                    expected='map-view position must be a table with x, y, ' ..
                        'and z coordinates',
                },
                {
                    position={x=-1, y=2, z=3},
                    expected='map-view x coordinate must be a nonnegative ' ..
                        'integer',
                },
                {
                    position={x=1, y=2.5, z=3},
                    expected='map-view y coordinate must be a nonnegative ' ..
                        'integer',
                },
                {
                    position={x=1, y=2, z='3'},
                    expected='map-view z coordinate must be a nonnegative ' ..
                        'integer',
                },
            }) do
            assert.has_error(function()
                ds.setViewPos(case.position)
            end, case.expected)
        end
        assert.equals(0, cleanup.pending_count(registry))

        assert.has_error(function()
            ds.getViewPos('middle')
        end, 'screen origin must be a ds.EScreenOrigin value')
        assert.has_error(function()
            ds.setViewPos({x=1, y=2, z=3}, 'middle')
        end, 'screen origin must be a ds.EScreenOrigin value')

        map_view_dimensions_failure =
            'injected map-view dimensions failure'
        assert.has_error(function()
            ds.getViewPos(EScreenOrigin.CENTER)
        end, 'DwarfSpec could not query the current map-view dimensions: ' ..
            'injected map-view dimensions failure')
        map_view_dimensions_failure = nil

        map_view_set_failure = 'injected map-view setter failure'
        local ok, failure = pcall(ds.setViewPos,
            {x=40, y=50, z=6})
        assert.is_false(ok)
        assert.matches('injected map-view setter failure',
            failure, 1, true)
        assert.is_true(run.mount_cleanup_probe().map_view_position_active)

        map_view_set_failure = nil
        reset('failed map-view position example cleanup')
        assert.same({x=12, y=34, z=5}, map_view_position)
        assert.is_false(run.mount_cleanup_probe().map_view_position_active)
    end)

    it('redraws the subject screen and waits by default', function()
        local mounted = ds.mount(TestWidget)
        local baseline_waits = wait_until_calls

        assert.equals(mounted, mounted:redraw())

        assert.equals(1, screen.invalidation_count)
        assert.equals(baseline_waits + 1, wait_until_calls)
    end)

    it('can redraw without waiting for the resulting render', function()
        local mounted = ds.mount(TestWidget)
        local baseline_waits = wait_until_calls

        assert.equals(mounted, mounted:redraw({wait=false}))

        assert.equals(1, screen.invalidation_count)
        assert.equals(baseline_waits, wait_until_calls)
    end)

    it('validates redraw options', function()
        local mounted = ds.mount(TestWidget)

        local cases = {
            {
                options=false,
                expected='redraw options must be a table',
            },
            {
                options={wait='yes'},
                expected='redraw wait option must be a boolean',
            },
            {
                options={unknown=true},
                expected='unsupported redraw option: unknown',
            },
        }
        for _, case in ipairs(cases) do
            local ok, failure = pcall(
                mounted.redraw, mounted, case.options)

            assert.is_false(ok)
            assert.matches(case.expected, failure, 1, true)
        end
    end)

    it('rejects redraw through a stale subject', function()
        local mounted = ds.mount(TestWidget)
        ds.unmount()

        local ok, failure = pcall(mounted.redraw, mounted)

        assert.is_false(ok)
        assert.matches('DwarfSpec redraw rejected stale subject',
            failure, 1, true)
        assert.matches('no current mount exists',
            failure, 1, true)
    end)

    it('sends button and wheel input at the current pointer position',
            function()
        local mounted = ds.mount(TestWidget, {
            frame_body={x1=10, y1=20, x2=14, y2=24},
        })
        assert.equals(EMouseButton.LEFT, ds.EMouseButton.LEFT)
        assert.equals(EMouseButton.SCROLL_DOWN,
            ds.EMouseButton.SCROLL_DOWN)
        assert.equals(EInputState.CLICK, ds.EInputState.CLICK)
        assert.equals(EPointerSpace.GRID, ds.EPointerSpace.GRID)
        assert.equals(EPointerSpace.PIXELS, ds.EPointerSpace.PIXELS)
        assert.equals(EPointerAnchor.CENTER, ds.EPointerAnchor.CENTER)
        assert.equals(EPointerAnchor.TOP_LEFT, ds.EPointerAnchor.TOP_LEFT)
        assert.equals(EPointerAnchor.BOTTOM_RIGHT,
            ds.EPointerAnchor.BOTTOM_RIGHT)
        assert.equals(EScreenOrigin.TOP_LEFT, ds.EScreenOrigin.TOP_LEFT)
        assert.equals(EScreenOrigin.CENTER, ds.EScreenOrigin.CENTER)
        assert.equals(EScreenOrigin.BOTTOM_RIGHT,
            ds.EScreenOrigin.BOTTOM_RIGHT)
        assert.is_nil(ds.EMouseInput)
        assert.has_error(function()
            ds.mouseInput(EMouseButton.LEFT)
        end, 'mouse input requires a pointer position; call ' ..
            'ds.move_pointer() or subject:hover() first')

        mounted:hover(EPointerAnchor.TOP_LEFT)
        for _, input in ipairs({
                {EMouseButton.LEFT},
                {EMouseButton.RIGHT},
                {EMouseButton.MIDDLE},
                {EMouseButton.SCROLL_UP},
                {EMouseButton.SCROLL_DOWN}}) do
            df.global.gps.mouse_x = -1
            df.global.gps.mouse_y = -1
            df.global.gps.precise_mouse_x = -1
            df.global.gps.precise_mouse_y = -1
            ds.mouseInput(input[1], input[2])
        end

        assert.same({
            '_MOUSE_L',
            '_MOUSE_R',
            '_MOUSE_M',
            'CONTEXT_SCROLL_UP',
            'CONTEXT_SCROLL_DOWN',
        }, {
            simulated_inputs[1].key,
            simulated_inputs[2].key,
            simulated_inputs[3].key,
            simulated_inputs[4].key,
            simulated_inputs[5].key,
        })
        for _, input in ipairs(simulated_inputs) do
            assert.equals('native-screen', input.screen.name)
            assert.same({10, 20}, {input.x, input.y})
            assert.same({105, 164}, {input.pixel_x, input.pixel_y})
            assert.is_true(input.mouse_focus)
            assert.equals(1, input.tracking_on)
        end
        assert.same({10, 20}, {dfhack.screen.getMousePos()})
        assert.same({10, 20, 105, 164}, {
            df.global.gps.mouse_x,
            df.global.gps.mouse_y,
            df.global.gps.precise_mouse_x,
            df.global.gps.precise_mouse_y,
        })
        assert.is_false(df.global.enabler.mouse_focus)
        assert.equals(0, df.global.enabler.tracking_on)
        assert.has_error(function() ds.mouseInput('unknown') end,
            'unsupported mouse button: unknown')
        assert.has_error(function()
            ds.mouseInput(EMouseButton.LEFT, 'unknown')
        end, 'unsupported mouse button action: unknown')
        assert.has_error(function()
            ds.mouseInput(EMouseButton.SCROLL_DOWN,
                EInputState.CLICK)
        end, 'mouse wheel input does not accept a button action')
    end)

    it('batches wheel input with one render wait and validates its options',
            function()
        local mounted = ds.mount(TestWidget, {
            frame_body={x1=10, y1=20, x2=14, y2=24},
        })
        local baseline_waits = wait_until_calls

        assert.equals(mounted, mounted:mouseWheel({
            direction=EMouseButton.SCROLL_DOWN,
            steps=3,
            anchor='top_left',
        }))

        assert.equals(baseline_waits + 2, wait_until_calls,
            'subject routing settles pointer movement and then the batch')
        assert.same({
            'CONTEXT_SCROLL_DOWN',
            'CONTEXT_SCROLL_DOWN',
            'CONTEXT_SCROLL_DOWN',
        }, {
            simulated_inputs[1].key,
            simulated_inputs[2].key,
            simulated_inputs[3].key,
        })
        for _, input in ipairs(simulated_inputs) do
            assert.same({10, 20}, {input.x, input.y})
            assert.is_true(input.mouse_focus)
            assert.equals(1, input.tracking_on)
        end
        assert.is_false(df.global.enabler.mouse_focus)
        assert.equals(0, df.global.enabler.tracking_on)

        local cases = {
            {options=nil, expected='mouseWheel options must be a table'},
            {options={}, expected='mouseWheel direction must be SCROLL_UP or SCROLL_DOWN'},
            {options={direction=EMouseButton.LEFT}, expected='mouseWheel direction must be SCROLL_UP or SCROLL_DOWN'},
            {options={direction=EMouseButton.SCROLL_DOWN, steps=0}, expected='mouseWheel steps must be a positive integer'},
            {options={direction=EMouseButton.SCROLL_DOWN, steps=1.5}, expected='mouseWheel steps must be a positive integer'},
            {options={direction=EMouseButton.SCROLL_DOWN, extra=true}, expected='unsupported mouseWheel option: extra'},
        }
        for _, case in ipairs(cases) do
            assert.has_error(function() ds.mouseWheel(case.options) end,
                case.expected)
        end
        assert.has_error(function()
            ds.mouseWheel({direction=EMouseButton.SCROLL_DOWN, anchor='center'})
        end, 'mouseWheel anchor requires a subject')
    end)

    it('restores mouse focus after a mid-batch wheel-input failure',
            function()
        local mounted = ds.mount(TestWidget, {
            frame_body={x1=10, y1=20, x2=14, y2=24},
        })
        mounted:move_pointer('top_left')
        simulate_input_dispatch = function()
            simulate_input_failure = 'injected second wheel failure'
        end

        local ok, failure = pcall(ds.mouseWheel, {
            direction=EMouseButton.SCROLL_DOWN,
            steps=2,
        })

        simulate_input_dispatch = nil
        assert.is_false(ok)
        assert.matches('injected second wheel failure', failure, 1, true)
        assert.equals(1, #simulated_inputs)
        assert.is_false(df.global.enabler.mouse_focus)
        assert.equals(0, df.global.enabler.tracking_on)
    end)

    it('routes every subject input family through the live input screen',
            function()
        local native_callback_calls = 0
        local overlay_callback_calls = 0
        local native_control = make_native_widget(
            'NativeControl', 'df.widget_button', nil, {
                rect={x1=2, y1=3, x2=5, y2=6},
                onInput=function()
                    native_callback_calls = native_callback_calls + 1
                end,
            })
        native_root.children = {native_control}
        local overlay_control = {
            view_id='OverlayControl',
            subviews={},
            frame_body={x1=20, y1=10, x2=24, y2=12},
            visible=true,
            active=true,
            onInput=function()
                overlay_callback_calls = overlay_callback_calls + 1
            end,
        }
        local overlay_root = {
            view_id='OverlayRoot',
            subviews={overlay_control},
            frame_body={x1=19, y1=9, x2=25, y2=13},
            visible=true,
            active=true,
        }
        overlay_state.db['gui/example.InputOverlay'] = {
            widget=overlay_root,
        }
        overlay_state.config['gui/example.InputOverlay'] = {enabled=true}
        ds.mountNativeScreen()
        local native_subject = ds.get('NativeControl')
        local overlay_subject = ds.get('OverlayControl', {
            source=ds.ESubjectSource.OVERLAY,
            overlay='gui/example.InputOverlay',
        })

        local top_level_screen = {name='top-level'}
        local native_subject_screen = {name='native-subject'}
        local overlay_subject_screen = {name='overlay-subject'}
        local first_type_screen = {name='type-first'}
        local second_type_screen = {name='type-second'}
        local native_click_screen = {name='native-click'}
        local overlay_click_screen = {name='overlay-click'}

        current_native_screen = top_level_screen
        ds.input('TOP_LEVEL')
        current_native_screen = native_subject_screen
        native_subject:input('NATIVE_SUBJECT')
        current_native_screen = overlay_subject_screen
        overlay_subject:input('OVERLAY_SUBJECT')
        current_native_screen = first_type_screen
        simulate_input_dispatch = function(_, key)
            if key == 'STRING_A065' then
                current_native_screen = second_type_screen
            end
        end
        overlay_subject:type('AB')
        simulate_input_dispatch = nil
        df.global.gps.mouse_x = -1
        df.global.gps.mouse_y = -1
        df.global.gps.precise_mouse_x = -1
        df.global.gps.precise_mouse_y = -1
        current_native_screen = native_click_screen
        native_subject:click()
        df.global.gps.mouse_x = -1
        df.global.gps.mouse_y = -1
        df.global.gps.precise_mouse_x = -1
        df.global.gps.precise_mouse_y = -1
        current_native_screen = overlay_click_screen
        overlay_subject:click()

        assert.same({
            'TOP_LEVEL',
            'NATIVE_SUBJECT',
            'OVERLAY_SUBJECT',
            'STRING_A065',
            'STRING_A066',
            '_MOUSE_L',
            '_MOUSE_L',
        }, {
            simulated_inputs[1].key,
            simulated_inputs[2].key,
            simulated_inputs[3].key,
            simulated_inputs[4].key,
            simulated_inputs[5].key,
            simulated_inputs[6].key,
            simulated_inputs[7].key,
        })
        assert.same({
            top_level_screen,
            native_subject_screen,
            overlay_subject_screen,
            first_type_screen,
            second_type_screen,
            native_click_screen,
            overlay_click_screen,
        }, {
            simulated_inputs[1].screen,
            simulated_inputs[2].screen,
            simulated_inputs[3].screen,
            simulated_inputs[4].screen,
            simulated_inputs[5].screen,
            simulated_inputs[6].screen,
            simulated_inputs[7].screen,
        })
        assert.same({3, 4}, {
            simulated_inputs[6].x,
            simulated_inputs[6].y,
        })
        assert.same({35, 36}, {
            simulated_inputs[6].pixel_x,
            simulated_inputs[6].pixel_y,
        })
        assert.same({22, 11}, {
            simulated_inputs[7].x,
            simulated_inputs[7].y,
        })
        assert.same({225, 92}, {
            simulated_inputs[7].pixel_x,
            simulated_inputs[7].pixel_y,
        })
        assert.equals(0, native_callback_calls)
        assert.equals(0, overlay_callback_calls)
    end)

    it('preserves overlay interposition and unhandled input fall-through',
            function()
        local overlay_calls = 0
        local backing_calls = 0
        local overlay_handles = false
        local overlay_root = {
            view_id='InputOverlay',
            subviews={},
            frame_body={x1=8, y1=6, x2=12, y2=8},
            visible=true,
            active=true,
        }
        overlay_state.db['gui/example.FallthroughOverlay'] = {
            widget=overlay_root,
        }
        overlay_state.config['gui/example.FallthroughOverlay'] = {
            enabled=true,
        }
        simulate_input_dispatch = function(received_screen, key)
            assert.equals(native_screen, received_screen)
            assert.equals('_MOUSE_L', key)
            overlay_calls = overlay_calls + 1
            if not overlay_handles then
                backing_calls = backing_calls + 1
            end
        end
        ds.mountNativeScreen()
        local subject = ds.root({
            source=ds.ESubjectSource.OVERLAY,
            overlay='gui/example.FallthroughOverlay',
        })

        subject:click()
        overlay_handles = true
        subject:click()

        assert.equals(2, overlay_calls)
        assert.equals(1, backing_calls)
    end)

    it('persists explicit button-down state until matching button-up input',
            function()
        local mounted = ds.mount(TestWidget, {
            frame_body={x1=10, y1=20, x2=14, y2=24},
        })
        mounted:move_pointer('top_left')

        local transitions = {
            {
                button=EMouseButton.LEFT,
                key='_MOUSE_L_DOWN',
                down_field='mouse_lbut_down',
                lift_field='mouse_lbut_lift',
                record_down='left_down',
                record_lift='left_lift',
            },
            {
                button=EMouseButton.RIGHT,
                key='_MOUSE_R_DOWN',
                down_field='mouse_rbut_down',
                lift_field='mouse_rbut_lift',
                record_down='right_down',
                record_lift='right_lift',
            },
            {
                button=EMouseButton.MIDDLE,
                key='_MOUSE_M_DOWN',
                down_field='mouse_mbut_down',
                lift_field='mouse_mbut_lift',
                record_down='middle_down',
                record_lift='middle_lift',
            },
        }

        for _, transition in ipairs(transitions) do
            mounted:move_pointer('top_left')
            df.global.gps.mouse_x = -1
            df.global.gps.mouse_y = -1
            df.global.gps.precise_mouse_x = -1
            df.global.gps.precise_mouse_y = -1
            ds.mouseInput(transition.button, EInputState.DOWN)
            local down_input = simulated_inputs[#simulated_inputs]
            assert.equals(transition.key, down_input.key)
            assert.same({10, 20, 105, 164}, {
                down_input.x,
                down_input.y,
                down_input.pixel_x,
                down_input.pixel_y,
            })
            assert.equals(1, down_input[transition.record_down])
            assert.equals(0, down_input[transition.record_lift])
            assert.equals(1, df.global.enabler[transition.down_field])
            assert.is_true(df.global.enabler.mouse_focus)
            assert.equals(1, df.global.enabler.tracking_on)

            mounted:move_pointer('bottom_right')
            assert.equals(1, df.global.enabler[transition.down_field])

            df.global.gps.mouse_x = -1
            df.global.gps.mouse_y = -1
            df.global.gps.precise_mouse_x = -1
            df.global.gps.precise_mouse_y = -1
            ds.mouseInput(transition.button, EInputState.UP)
            local up_input = simulated_inputs[#simulated_inputs]
            assert.is_nil(up_input.key)
            assert.same({14, 24, 145, 196}, {
                up_input.x,
                up_input.y,
                up_input.pixel_x,
                up_input.pixel_y,
            })
            assert.equals(0, up_input[transition.record_down])
            assert.equals(1, up_input[transition.record_lift])
            assert.equals(0, df.global.enabler[transition.down_field])
            assert.equals(0, df.global.enabler[transition.lift_field])
            assert.is_false(df.global.enabler.mouse_focus)
            assert.equals(0, df.global.enabler.tracking_on)
        end
    end)

    it('preserves paired pointer ownership and restores input failure flags',
            function()
        local mounted = ds.mount(TestWidget, {
            frame_body={x1=10, y1=20, x2=14, y2=24},
        })
        mounted:move_pointer('top_left')
        simulate_input_failure = 'injected simulateInput failure'

        local click_ok, click_failure = pcall(
            ds.mouseInput, EMouseButton.LEFT)
        assert.is_false(click_ok)
        assert.matches('injected simulateInput failure',
            click_failure, 1, true)
        assert.same({10, 20, 105, 164}, {
            df.global.gps.mouse_x,
            df.global.gps.mouse_y,
            df.global.gps.precise_mouse_x,
            df.global.gps.precise_mouse_y,
        })
        assert.is_false(df.global.enabler.mouse_focus)
        assert.equals(0, df.global.enabler.tracking_on)

        local down_ok, down_failure = pcall(
            ds.mouseInput, EMouseButton.LEFT, EInputState.DOWN)
        assert.is_false(down_ok)
        assert.matches('injected simulateInput failure',
            down_failure, 1, true)
        assert.equals(0, df.global.enabler.mouse_lbut_down)
        assert.equals(0, df.global.enabler.mouse_lbut_lift)
        assert.is_false(df.global.enabler.mouse_focus)
        assert.equals(0, df.global.enabler.tracking_on)

        ds.unmount()

        assert.same({90, 91}, {dfhack.screen.getMousePos()})
        assert.same({900, 910}, {dfhack.screen.getMousePixels()})
        assert.same({4, 5, 40, 50}, {
            df.global.gps.mouse_x,
            df.global.gps.mouse_y,
            df.global.gps.precise_mouse_x,
            df.global.gps.precise_mouse_y,
        })
        assert.equals(0, df.global.enabler.mouse_lbut_down)
        assert.equals(0, df.global.enabler.mouse_lbut_lift)
        assert.is_false(df.global.enabler.mouse_focus)
        assert.equals(0, df.global.enabler.tracking_on)
    end)

    it('routes input after a native screen change without rebinding subjects',
            function()
        local mounted = ds.mountNativeScreen()
        ds.move_pointer(4, 5)
        local lookup_count = native_widget_lookup_calls
        local next_screen = {
            name='replacement-screen',
            widgets={kind='replacement-root'},
        }
        current_native_screen = next_screen

        ds.input('SELECT')
        ds.mouseInput(EMouseButton.LEFT)
        current_native_screen = {
            name='wheel-screen',
            widgets={kind='replacement-root'},
        }
        local wheel_screen = current_native_screen
        ds.mouseInput(EMouseButton.SCROLL_DOWN)
        local wheel_batch_screen = {name='wheel-batch-screen'}
        simulate_input_dispatch = function(_, key)
            if key == 'CONTEXT_SCROLL_UP' then
                current_native_screen = wheel_batch_screen
            end
        end
        ds.mouseWheel({direction=EMouseButton.SCROLL_UP, steps=2})
        simulate_input_dispatch = nil
        ds.move_pointer(4, 5)
        assert.equals(native_root, mounted:raw())
        assert.equals(next_screen, simulated_inputs[1].screen)
        assert.equals(next_screen, simulated_inputs[2].screen)
        assert.equals(wheel_screen, simulated_inputs[3].screen)
        assert.equals(wheel_screen, simulated_inputs[4].screen)
        assert.equals(wheel_batch_screen, simulated_inputs[5].screen)
        assert.same({4, 5}, {
            df.global.gps.mouse_x,
            df.global.gps.mouse_y,
        })
        assert.is_true(native_widget_lookup_calls >= lookup_count)

        ds.unmount()

        assert.same({90, 91}, {dfhack.screen.getMousePos()})
        assert.equals(original_native_render_dispatcher,
            package.loaded['plugins.overlay'].render_viewscreen_widgets)
        assert.equals(0, native_screen.show_calls)
        assert.equals(0, native_screen.dismiss_calls)
        assert.equals(0, native_screen.resize_calls)
        assert.equals(0, native_screen.replace_calls)
        assert.equals(0, native_screen.navigation_calls)
        assert.equals(0, cleanup.pending_count(registry))
    end)

    it('searches visible root bounds for every owned mount category',
            function()
        screen_default_ch = string.byte(' ')
        write_screen_text(12, 6, 'Ready')
        for _, component_class in ipairs({
            TestWidget,
            TestOverlay,
            TestScreen,
        }) do
            ds.mount(component_class, {
                visible=true,
                frame_body={x1=10, y1=5, x2=20, y2=7},
            })
            assert.same({x1=12, y1=6, x2=16, y2=6},
                ds.search({text='Ready'}))
            ds.unmount()
        end
    end)

    it('searches the full native window and explicit rectangles', function()
        screen_default_ch = string.byte(' ')
        write_screen_text(70, 20, 'Native')
        ds.mountNativeScreen()

        local window_calls_before = window_size_calls
        assert.same({x1=70, y1=20, x2=75, y2=20},
            ds.search({text='Native'}))
        assert.equals(window_calls_before + 1, window_size_calls)
        assert.is_nil(ds.search(
            {text='Native'}, {x1=0, y1=0, x2=69, y2=24}))
        assert.same({x1=70, y1=20, x2=75, y2=20},
            ds.search(
                {text='Native'}, {x1=70, y1=20, x2=79, y2=24}))
    end)

    it('intersects Lua subjects and rectangles with owned root bounds',
            function()
        screen_default_ch = string.byte(' ')
        write_screen_text(8, 6, 'Child')
        local child = TestWidget({
            view_id='child',
            visible=true,
            frame_body={x1=7, y1=5, x2=14, y2=7},
            subviews={},
        })
        local root = TestWidget({
            visible=true,
            frame_body={x1=5, y1=4, x2=15, y2=8},
            subviews={child},
        })
        ds.mount(TestWidget, {
            visible=true,
            frame_body={x1=5, y1=4, x2=15, y2=8},
            subviews={child},
        })
        local subject = ds.get('child')

        assert.same({x1=8, y1=6, x2=12, y2=6},
            ds.search({text='Child'}, subject))
        assert.same({x1=8, y1=6, x2=12, y2=6},
            subject:search({text='Child'}))
        assert.same({x1=8, y1=6, x2=12, y2=6},
            ds.search(
                {text='Child'}, {x1=8, y1=6, x2=12, y2=6}))
        local reads_before = #screen_read_calls
        assert.is_nil(ds.search(
            {text='Child'}, {x1=30, y1=20, x2=35, y2=22}))
        assert.equals(reads_before, #screen_read_calls)
        assert.has_error(function()
            ds.search({}, {x1=30, y1=20, x2=35, y2=22})
        end, 'text search query.text must be a nonempty string')
        assert.equals(reads_before, #screen_read_calls)
        local subject_ok, subject_failure = pcall(subject.search, subject, {})
        assert.is_false(subject_ok)
        assert.matches('DwarfSpec subject failure: operation="search"',
            subject_failure, 1, true)
        assert.matches('text search query.text must be a nonempty string',
            subject_failure, 1, true)
    end)

    it('uses clipped native and registered-overlay subject scopes',
            function()
        screen_default_ch = string.byte(' ')
        local native_child = make_native_widget(
            'Partial', 'df.widget_text', nil, {
                rect={x1=-4, y1=3, x2=8, y2=5},
                flag={
                    VISIBILITY_VISIBLE=true,
                    VISIBILITY_ACTIVE=true,
                },
            })
        local inherited_hidden = make_native_widget(
            'InheritedHidden', 'df.widget_text', nil, {
                rect={x1=10, y1=3, x2=18, y2=5},
                flag={
                    VISIBILITY_VISIBLE=true,
                    VISIBILITY_ACTIVE=true,
                },
            })
        local hidden_parent = make_native_widget(
            'HiddenParent', 'df.widget_container', {inherited_hidden}, {
                flag={
                    VISIBILITY_VISIBLE=false,
                    VISIBILITY_ACTIVE=true,
                },
            })
        inherited_hidden.parent = hidden_parent
        native_root.children = {native_child, hidden_parent}
        local overlay_root = {
            view_id='overlay-root',
            subviews={},
            visible=true,
            active=true,
            frame_body={x1=30, y1=10, x2=45, y2=12},
        }
        overlay_state.db['gui/example.SearchOverlay'] = {
            widget=overlay_root,
        }
        overlay_state.config['gui/example.SearchOverlay'] = {enabled=true}
        write_screen_text(0, 4, 'Native')
        write_screen_text(32, 11, 'Overlay')
        ds.mountNativeScreen()

        assert.same({x1=0, y1=4, x2=5, y2=4},
            ds.search({text='Native'}, ds.get('Partial')))
        assert.has_error(function()
            ds.search(
                {text='Hidden'},
                ds.get({'HiddenParent', 'InheritedHidden'}))
        end, 'DwarfSpec search requires an effectively visible subject: ' ..
            'control_path="{\\"HiddenParent\\", ' ..
                '\\"InheritedHidden\\"}"')
        local overlay_subject = ds.root({
            source=ds.ESubjectSource.OVERLAY,
            overlay='gui/example.SearchOverlay',
        })
        assert.same({x1=32, y1=11, x2=38, y2=11},
            ds.search({text='Overlay'}, overlay_subject))
    end)

    it('leaves mount, render, pointer, cleanup, and capture state unchanged',
            function()
        screen_default_ch = string.byte(' ')
        write_screen_text(3, 2, 'Stable')
        run.captures = {existing={kind='capture'}}
        local captures = run.captures
        ds.mount(TestWidget, {
            visible=true,
            frame_body={x1=1, y1=1, x2=12, y2=4},
        })
        local generation = current_tracker:capture()
        local cleanup_count = cleanup.pending_count(registry)
        local pointer_before = {
            x=df.global.gps.mouse_x,
            y=df.global.gps.mouse_y,
            precise_x=df.global.gps.precise_mouse_x,
            precise_y=df.global.gps.precise_mouse_y,
        }
        local published_before = #published
        local invalidations_before = screen.invalidation_count

        assert.same({x1=3, y1=2, x2=8, y2=2},
            ds.search({text='Stable'}, ds.root()))

        assert.equals(generation, current_tracker:capture())
        assert.equals(cleanup_count, cleanup.pending_count(registry))
        assert.same(pointer_before, {
            x=df.global.gps.mouse_x,
            y=df.global.gps.mouse_y,
            precise_x=df.global.gps.precise_mouse_x,
            precise_y=df.global.gps.precise_mouse_y,
        })
        assert.equals(published_before, #published)
        assert.equals(invalidations_before, screen.invalidation_count)
        assert.equals(captures, run.captures)
        assert.same({existing={kind='capture'}}, run.captures)
        assert.is_false(run.mount_cleanup_probe().pointer_active)

        ds.redraw()
        assert.equals('mount:1/<root>',
            published[#published - 1].payload.subject_identity)
    end)

    it('rejects missing mounts, malformed areas, and inactive screens',
            function()
        assert.has_error(function()
            ds.search({text='x'})
        end, 'DwarfSpec search requires a current mount; call ' ..
            'ds.mount(component, options) or ds.mountNativeScreen() first')

        screen_default_ch = string.byte(' ')
        ds.mount(TestWidget, {
            visible=true,
            frame_body={x1=0, y1=0, x2=10, y2=3},
        })
        assert.has_error(function()
            ds.search({text='x'}, {x1=4, y1=0, x2=3, y2=1})
        end, 'text search area must not be horizontally inverted')
        assert.has_error(function()
            ds.search({text='x'}, false)
        end, 'text search area must be a table')
        screen.active = false
        assert.has_error(function()
            ds.search({text='x'})
        end, 'search screen is not currently active')
    end)

    it('rejects hidden, unbounded, offscreen, and unreadable subjects',
            function()
        screen_default_ch = string.byte(' ')
        local hidden = TestWidget({
            view_id='hidden',
            visible=false,
            frame_body={x1=1, y1=1, x2=4, y2=2},
            subviews={},
        })
        local unbounded = TestWidget({
            view_id='unbounded',
            visible=true,
            subviews={},
        })
        local offscreen = TestWidget({
            view_id='offscreen',
            visible=true,
            frame_body={x1=90, y1=30, x2=95, y2=35},
            subviews={},
        })
        ds.mount(TestWidget, {
            visible=true,
            frame_body={x1=0, y1=0, x2=100, y2=40},
            subviews={hidden, unbounded, offscreen},
        })
        assert.has_error(function()
            ds.search({text='x'}, ds.get('hidden'))
        end, 'DwarfSpec search requires an effectively visible subject: ' ..
            'control_path="hidden"')
        assert.has_error(function()
            ds.search({text='x'}, ds.get('unbounded'))
        end, 'DwarfSpec search subject has no visible body bounds: ' ..
            'control_path="unbounded"')
        assert.has_error(function()
            ds.search({text='x'}, ds.get('offscreen'))
        end, 'DwarfSpec search subject has no usable visible body bounds ' ..
            'within the current window')

        ds.unmount()
        screen_default_ch = nil
        ds.mount(TestWidget, {
            visible=true,
            frame_body={x1=2, y1=2, x2=4, y2=3},
        })
        assert.has_error(function()
            ds.search({text='x'})
        end, 'text search effective region has no readable screen cells: ' ..
            '{x1=2,y1=2,x2=4,y2=3}')
    end)

    it('preserves retained-subject ownership and replacement failures',
            function()
        screen_default_ch = string.byte(' ')
        local old_mount = ds.mount(TestWidget, {
            visible=true,
            frame_body={x1=0, y1=0, x2=5, y2=2},
        })
        ds.unmount()
        ds.mount(TestWidget, {
            visible=true,
            frame_body={x1=0, y1=0, x2=5, y2=2},
        })
        local ok, failure = pcall(ds.search, {text='x'}, old_mount)
        assert.is_false(ok)
        assert.matches('search rejected stale subject', failure, 1, true)
        assert.matches('from mount 1; current mount is 2', failure, 1, true)

        ds.unmount()
        local original = make_native_widget(
            'Replaceable', 'df.widget_text', nil, {
                rect={x1=1, y1=1, x2=5, y2=2},
                flag={
                    VISIBILITY_VISIBLE=true,
                    VISIBILITY_ACTIVE=true,
                },
            })
        native_root.children = {original}
        ds.mountNativeScreen()
        local retained = ds.get('Replaceable')
        native_root.children[1] = make_native_widget(
            'Replaceable', 'df.widget_text', nil, {
                rect={x1=1, y1=1, x2=5, y2=2},
                flag={
                    VISIBILITY_VISIBLE=true,
                    VISIBILITY_ACTIVE=true,
                },
            })
        ok, failure = pcall(ds.search, {text='x'}, retained)
        assert.is_false(ok)
        assert.matches('rejected stale native subject', failure, 1, true)
        assert.matches('widget was replaced', failure, 1, true)
    end)

    it('routes input to a native child while retaining the mounted root',
            function()
        local root_native = {name='root'}
        local child_native = {name='child', parent=root_native}
        local unrelated = {name='unrelated'}
        local current = child_native
        local owned_screen = {
            active=true,
            _native=root_native,
        }
        local target = interaction_target.new_owned_screen(owned_screen, {
            is_active=function(screen_value)
                return screen_value.active
            end,
            resolve_native_screen=function(screen_value)
                return ds_factory.resolve_native_screen(
                    screen_value, function() return current end)
            end,
        })

        assert.equals(child_native, target:input_screen('input'))
        current = unrelated
        assert.equals(root_native, target:input_screen('input'))
        current = nil
        assert.equals(root_native, target:input_screen('input'))
    end)

    it('publishes structured command results and bounded diagnostics',
            function()
        assert.equals('ok:value', ds.sample_success('value'))
        local ok, failure = pcall(ds.sample_failure)

        assert.is_false(ok)
        assert.matches('deliberate command failure', failure, 1, true)
        assert.equals(EventType.COMMAND_STARTED, published[1].type)
        assert.equals('sample_success', published[1].payload.name)
        assert.equals(EventType.COMMAND_FINISHED, published[2].type)
        assert.equals(TestStatus.SUCCESS, published[2].payload.status)
        assert.equals(2, published[2].payload.duration_ms)
        assert.equals(EventType.COMMAND_STARTED, published[3].type)
        assert.equals(EventType.COMMAND_FINISHED, published[4].type)
        assert.equals(TestStatus.ERROR, published[4].payload.status)
        assert.equals(EventType.DIAGNOSTIC_RECORDED, published[5].type)
        assert.equals('command_failure', published[5].payload.kind)
        assert.matches('deliberate command failure',
            published[5].payload.content.message, 1, true)
    end)
end)
