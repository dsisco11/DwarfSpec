-- Production live-game namespace exported into isolated Busted specs.

local M = {}

---Binds validated project definitions to one public namespace and runner.
---@param ds table
---@param commands table<string, table>
---@param command_runner dwarfspec.CommandRunner
function M.bind_project_commands(ds, commands, command_runner)
    assert(type(ds) == 'table', 'project command binding requires a namespace')
    assert(type(commands) == 'table',
        'project command binding requires definitions')
    assert(type(command_runner) == 'table' and
        type(command_runner.invoke) == 'function' and
        type(command_runner.registerProject) == 'function',
        'project command binding requires the verified runner')
    for name, command in pairs(commands) do
        command_runner:registerProject(command.definition, command.source)
        ---Invokes one source-attributed project definition through the runner.
        ---@param arguments? table
        ---@param command_options? dwarfspec.CommandOptions
        ---@return any
        ds[name] = function(arguments, command_options)
            return command_runner:invoke(name, arguments or {}, command_options)
        end
    end
end

---Loads an installed DwarfSpec module or its source-tree equivalent.
---@param package_root string
---@param module_name string
---@param dependencies? table
---@return table
function M.load_automation_module(package_root, module_name, dependencies)
    dependencies = dependencies or {}
    local open_file = dependencies.open_file or io.open
    local load_file = dependencies.load_file or loadfile
    local require_module = dependencies.require_module or require
    local source_path = package_root .. '/src/' ..
        module_name:gsub('%.', '/') .. '.lua'
    local source_file = open_file(source_path, 'rb')
    if source_file then
        source_file:close()
        return assert(load_file(source_path))()
    end
    local ok, module = pcall(require_module, module_name)
    if ok then return module end
    error(module, 0)
end

local load_automation_module = M.load_automation_module

---Returns whether a mounted screen is still active.
---@param screen table
---@return boolean
local function is_active(screen)
    if type(screen.isActive) ~= 'function' then return false end
    local ok, active = pcall(screen.isActive, screen)
    return ok and not not active
end

---Returns the top native child belonging to a shown GUI screen, or its root.
---@param screen table
---@param current_viewscreen function|nil
---@return userdata
function M.resolve_native_screen(screen, current_viewscreen)
    assert(screen._native, 'input screen is not shown')
    if current_viewscreen then
        local ok, current = pcall(current_viewscreen)
        if ok then
            local candidate = current
            while candidate do
                if candidate == screen._native then return current end
                candidate = candidate.parent
            end
        end
    end
    return screen._native
end

---Creates the run-scoped live interaction namespace.
---@param package_root string
---@param project table
---@param scheduler_module table
---@param scheduler table
---@param cleanup_module table
---@param cleanup_registry table
---@param extensions table
---@param mount_dependencies table|nil
---@param run_capabilities table
---@return table
function M.new(package_root, project, scheduler_module, scheduler,
        cleanup_module, cleanup_registry, extensions, mount_dependencies,
        run_capabilities, command_runner)
    assert(type(run_capabilities) == 'table',
        'DwarfSpec ds factory requires injected run capabilities')
    assert(command_runner == nil or type(command_runner) == 'table' and
        type(command_runner.invoke) == 'function' and
        type(command_runner.registerBuiltin) == 'function' and
        type(command_runner.registerProject) == 'function' and
        type(command_runner.setRuntimeDependencies) == 'function' and
        type(command_runner.assertHandleExecution) == 'function',
        'DwarfSpec command runner has an invalid verified interface')
    local cleanup_handle = load_automation_module(package_root,
        'dwarfspec.driver.cleanup.cleanup_transaction_handle')
    local example_cleanup_marker = cleanup_module.mark(cleanup_registry)
    local recurring_operation_module = load_automation_module(package_root,
        'dwarfspec.driver.simulation.recurring_operation')
    local recurring_operation = recurring_operation_module.new({
        schedule=run_capabilities.recurring.schedule,
        cancel=run_capabilities.recurring.cancel,
        is_scheduled=run_capabilities.recurring.is_scheduled,
        report_failure=run_capabilities.recurring.report_failure,
        register_cleanup=run_capabilities.cleanup.register,
    })
    local unit_speed_command = load_automation_module(package_root,
        'dwarfspec.driver.commands.unit_speed')
    local unit_position_command = load_automation_module(package_root,
        'dwarfspec.driver.commands.unit_position')
    local unit_speed_controller_module = load_automation_module(package_root,
        'dwarfspec.driver.simulation.unit_speed_controller')
    local unit_target_adapter_module = load_automation_module(package_root,
        'dwarfspec.driver.simulation.unit_target_adapter')
    local unit_action_adapter_module = load_automation_module(package_root,
        'dwarfspec.driver.simulation.unit_action_adapter')
    local unit_job_travel_module = load_automation_module(package_root,
        'dwarfspec.driver.simulation.unit_job_travel')
    local unit_position_adapter_module = load_automation_module(package_root,
        'dwarfspec.driver.simulation.unit_position_adapter')
    local unit_position_controller_module = load_automation_module(package_root,
        'dwarfspec.driver.simulation.unit_position_controller')
    local unit_native_module = load_automation_module(package_root,
        'dwarfspec.driver.simulation.unit_native')
local diagnostics_module = load_automation_module(package_root,
    'dwarfspec.driver.diagnostics.diagnostics')
local pointer_adapter_module = load_automation_module(package_root,
    'dwarfspec.driver.input.pointer_adapter')
local overlay_registration_module = load_automation_module(package_root,
    'dwarfspec.driver.overlay.overlay_registration')
local component_module = load_automation_module(package_root,
    'dwarfspec.driver.mount.component')
local mount_context_module = load_automation_module(package_root,
    'dwarfspec.driver.mount.mount_context')
local testbed_adapter_module = load_automation_module(package_root,
    'dwarfspec.driver.mount.testbed_adapter')
local mount_adapters_module = load_automation_module(package_root,
    'dwarfspec.driver.mount.mount_adapters')
local overlay_mount_module = load_automation_module(package_root,
    'dwarfspec.driver.mount.overlay_mount')
local render_instrumentation = load_automation_module(package_root,
    'dwarfspec.driver.render.render_instrumentation')
local native_render_observer_module = load_automation_module(package_root,
    'dwarfspec.driver.render.native_render_observer')
local render_tracker_module = load_automation_module(package_root,
    'dwarfspec.driver.render.render_tracker')
local subject_module = load_automation_module(package_root,
    'dwarfspec.driver.subjects.subject')
local interaction_target_module = load_automation_module(package_root,
    'dwarfspec.driver.subjects.interaction_target')
local interaction_target_resolver_module = load_automation_module(package_root,
    'dwarfspec.driver.mount.interaction_target_resolver')
local click_runtime_module = load_automation_module(package_root,
    'dwarfspec.driver.input.click_runtime')
local map_view_runtime_module = load_automation_module(package_root,
    'dwarfspec.driver.game.map_view_runtime')
local save_game_runtime_module = load_automation_module(package_root,
    'dwarfspec.driver.game.save_game_runtime')
local search_runtime_module = load_automation_module(package_root,
    'dwarfspec.driver.commands.search_runtime')
local lua_view_adapter_module = load_automation_module(package_root,
    'dwarfspec.driver.subjects.lua_view_adapter')
local native_attachment_module = load_automation_module(package_root,
    'dwarfspec.driver.mount.native_attachment')
local native_widget_adapter_module = load_automation_module(package_root,
    'dwarfspec.driver.subjects.native_widget_adapter')
local native_game_ui_path_module = load_automation_module(package_root,
    'dwarfspec.driver.subjects.native_game_ui_path')
local overlay_registry_adapter_module = load_automation_module(package_root,
    'dwarfspec.driver.subjects.overlay_registry_adapter')
local subject_paths_module = load_automation_module(package_root,
    'dwarfspec.driver.subjects.subject_paths')
local subject_requests_module = load_automation_module(package_root,
    'dwarfspec.driver.subjects.subject_requests')
local identity_labels = load_automation_module(package_root,
    'dwarfspec.support.identity_labels')
local EResolutionStage = load_automation_module(package_root,
    'dwarfspec.driver.subjects.native_resolution_stages')
local EMouseButton = load_automation_module(package_root,
    'dwarfspec.driver.input.mouse_buttons')
local EInputState = load_automation_module(package_root,
    'dwarfspec.driver.input.input_states')
local EPointerSpace = load_automation_module(package_root,
    'dwarfspec.driver.input.pointer_spaces')
local EPointerAnchor = load_automation_module(package_root,
    'dwarfspec.driver.input.pointer_anchors')
local EScreenOrigin = load_automation_module(package_root,
    'dwarfspec.driver.screen_origins')
local ESubjectSource = load_automation_module(package_root,
    'dwarfspec.driver.subjects.subject_sources')
local EEvent = load_automation_module(package_root,
    'dwarfspec.driver.state_change_events')
local EventType = load_automation_module(package_root,
    'dwarfspec.protocol.enums.event_types')
local TestStatus = load_automation_module(package_root,
    'dwarfspec.protocol.enums.test_statuses')
local save_game_unload_module = load_automation_module(package_root,
    'dwarfspec.driver.game.save_game_unload')
local save_game_load_module = load_automation_module(package_root,
    'dwarfspec.driver.game.save_game_load')
local save_game_unload_command = load_automation_module(package_root,
    'dwarfspec.driver.commands.save_game_unload')
local save_game_load_command = load_automation_module(package_root,
    'dwarfspec.driver.commands.save_game_load')
local await_event_command = load_automation_module(package_root,
    'dwarfspec.driver.commands.await_event')
local text_search_command = load_automation_module(package_root,
    'dwarfspec.driver.commands.text_search')
local builtin_registrar_module = load_automation_module(package_root,
    'dwarfspec.driver.command.builtin_command_registrar')
local wait_runtime_module = load_automation_module(package_root,
    'dwarfspec.driver.runtime.wait_runtime')
local game_query_runtime_module = load_automation_module(package_root,
    'dwarfspec.driver.runtime.game_query_runtime')
local run_query_runtime_module = load_automation_module(package_root,
    'dwarfspec.driver.runtime.run_query_runtime')
local capture_runtime_module = load_automation_module(package_root,
    'dwarfspec.driver.runtime.capture_runtime')
local mount_query_runtime_module = load_automation_module(package_root,
    'dwarfspec.driver.runtime.mount_query_runtime')
local subject_query_runtime_module = load_automation_module(package_root,
    'dwarfspec.driver.runtime.subject_query_runtime')
local builtin_modules = {
    wait_frames=load_automation_module(package_root,
        'dwarfspec.driver.builtins.wait_frames'),
    wait_ticks=load_automation_module(package_root,
        'dwarfspec.driver.builtins.wait_ticks'),
    await=load_automation_module(package_root,
        'dwarfspec.driver.builtins.await'),
    await_event=load_automation_module(package_root,
        'dwarfspec.driver.builtins.await_event'),
    is_game_paused=load_automation_module(package_root,
        'dwarfspec.driver.builtins.is_game_paused'),
    get_game_speed=load_automation_module(package_root,
        'dwarfspec.driver.builtins.get_game_speed'),
    get_tick=load_automation_module(package_root,
        'dwarfspec.driver.builtins.get_tick'),
    get_time=load_automation_module(package_root,
        'dwarfspec.driver.builtins.get_time'),
    get_save_directory_name=load_automation_module(package_root,
        'dwarfspec.driver.builtins.get_save_directory_name'),
    has_focus=load_automation_module(package_root,
        'dwarfspec.driver.builtins.has_focus'),
    current_run=load_automation_module(package_root,
        'dwarfspec.driver.builtins.current_run'),
    root=load_automation_module(package_root,
        'dwarfspec.driver.builtins.root'),
    get=load_automation_module(package_root,
        'dwarfspec.driver.builtins.get'),
    inspect=load_automation_module(package_root,
        'dwarfspec.driver.builtins.inspect'),
    capture_view_tree=load_automation_module(package_root,
        'dwarfspec.driver.builtins.capture_view_tree'),
    capture_screen=load_automation_module(package_root,
        'dwarfspec.driver.builtins.capture_screen'),
    subject_raw=load_automation_module(package_root,
        'dwarfspec.driver.builtins.subject_raw'),
    subject_get_focus_list=load_automation_module(package_root,
        'dwarfspec.driver.builtins.subject_get_focus_list'),
    search=load_automation_module(package_root,
        'dwarfspec.driver.builtins.search'),
    click=load_automation_module(package_root,
        'dwarfspec.driver.builtins.click'),
    get_view_pos=load_automation_module(package_root,
        'dwarfspec.driver.builtins.get_view_pos'),
    set_view_pos=load_automation_module(package_root,
        'dwarfspec.driver.builtins.set_view_pos'),
    mount_save_game=load_automation_module(package_root,
        'dwarfspec.driver.builtins.mount_save_game'),
    stage_overlay_registration=load_automation_module(package_root,
        'dwarfspec.driver.builtins.stage_overlay_registration'),
    register_cleanup=load_automation_module(package_root,
        'dwarfspec.driver.builtins.register_cleanup'),
}
local game_state_command = load_automation_module(package_root,
    'dwarfspec.driver.commands.game_state')
local mount_command = load_automation_module(package_root,
    'dwarfspec.driver.commands.mount')
local input_command = load_automation_module(package_root,
    'dwarfspec.driver.commands.input')
local native_subject_source_module = load_automation_module(package_root,
    'dwarfspec.driver.subjects.native_subject_source')
local command_observer_module = load_automation_module(package_root,
    'dwarfspec.driver.render.command_observer')
    extensions = extensions or {settings={}, commands={}}
    mount_dependencies = mount_dependencies or {}
    local unit_system

    ---Returns the shared lazily composed unit simulation system for this run.
    ---@return table
    local function get_unit_system()
        if unit_system then return unit_system end
        local native = mount_dependencies.unit_simulation or {}

        ---Returns occupancy for one valid map coordinate.
        ---@param position table
        ---@return any
        local function get_occupancy(position)
            local block = dfhack.maps.getTileBlock(position)
            if block == nil then return nil end
            return block.occupancy[position.x % 16][position.y % 16]
        end

        local positions = unit_position_controller_module.new({
            adapter=unit_position_adapter_module.new({
                is_map_loaded=native.is_map_loaded or dfhack.isMapLoaded,
                is_valid_position=native.is_valid_position or
                    dfhack.maps.isValidTilePos,
                resolve_unit=native.resolve_unit or df.unit.find,
                get_occupancy=native.get_occupancy or get_occupancy,
                teleport=native.teleport or dfhack.units.teleport,
                is_projectile=native.is_projectile or function(unit)
                    return unit.flags1.projectile
                end,
                has_rider=native.has_rider or unit_native_module.has_rider,
                is_rider=native.is_rider or unit_native_module.is_rider,
            }),
            register_cleanup=run_capabilities.cleanup.register,
        })
        local travel = unit_job_travel_module.new({
            resolve_unit=native.resolve_unit or df.unit.find,
            is_valid_position=native.is_valid_position or
                dfhack.maps.isValidTilePos,
            can_walk_between=native.can_walk_between or
                dfhack.maps.canWalkBetween,
            is_tile_visible=native.is_tile_visible or
                dfhack.maps.isTileVisible,
            resize_vector=native.resize_vector or function(vector, size)
                vector:resize(size)
            end,
            dragger_relationship=native.dragger_relationship or
                df.unit_relationship_type.Dragger,
            draggee_relationship=native.draggee_relationship or
                df.unit_relationship_type.Draggee,
            position_controller=positions,
        })
        local targets = unit_target_adapter_module.new({
            is_world_loaded=native.is_world_loaded or dfhack.isWorldLoaded,
            is_map_loaded=native.is_map_loaded or dfhack.isMapLoaded,
            is_fortress_mode=native.is_fortress_mode or
                dfhack.world.isFortressMode,
            enumerate_units=native.enumerate_units or
                dfhack.units.getCitizens,
            resolve_unit=native.resolve_unit or df.unit.find,
            is_active=native.is_active or dfhack.units.isActive,
            is_alive=native.is_alive or dfhack.units.isAlive,
            is_citizen=native.is_citizen or dfhack.units.isCitizen,
            is_resident=native.is_resident or dfhack.units.isResident,
        })
        local actions = unit_action_adapter_module.new({
            set_group_action_timers=native.set_group_action_timers or
                dfhack.units.setGroupActionTimers,
            all_action_group=native.all_action_group or
                df.unit_action_type_group.All,
        })
        unit_system = {
            positions=positions,
            speed=unit_speed_controller_module.new({
                recurring=recurring_operation,
                targets=targets,
                actions=actions,
                job_travel=travel,
                position_controller=positions,
                register_cleanup=run_capabilities.cleanup.register,
            }),
        }
        return unit_system
    end
    local wait_settings = extensions.settings.wait or {}
    local pointer_screen = mount_dependencies.pointer_screen or dfhack.screen
    local pointer_gui = mount_dependencies.pointer_gui or dfhack.gui
    local pointer_gps = mount_dependencies.pointer_gps or df.global.gps
    local pointer_enabler =
        mount_dependencies.pointer_enabler or df.global.enabler

    ---Returns the current effective grid and pixel geometry from DF.
    ---@return DwarfSpecPointerGeometry
    local function get_production_pointer_geometry()
        local gps = assert(pointer_gps,
            'DwarfSpec requires df.global.gps for pointer geometry')
        return {
            grid_width=gps.dimx,
            grid_height=gps.dimy,
            pixel_width=gps.screen_pixel_x,
            pixel_height=gps.screen_pixel_y,
            cell_pixel_width=gps.tile_pixel_x,
            cell_pixel_height=gps.tile_pixel_y,
        }
    end

    local get_pointer_geometry = mount_dependencies.get_pointer_geometry or
        get_production_pointer_geometry
    local context = {
        package_root=package_root,
        project=project,
        scheduler=scheduler,
        scheduler_module=scheduler_module,
        cleanup_module=cleanup_module,
        cleanup_registry=cleanup_registry,
        command_runner=command_runner,
        pointer=pointer_adapter_module.new(cleanup_module, cleanup_registry, {
            get_geometry=get_pointer_geometry,
            screen=pointer_screen,
            gui=pointer_gui,
            gps=pointer_gps,
            enabler=pointer_enabler,
        }),
        run=scheduler.run,
        current_viewscreen=mount_dependencies.current_viewscreen or
            function() return dfhack.gui.getCurViewscreen(true) end,
        get_window_size=mount_dependencies.get_window_size or
            function() return dfhack.screen.getWindowSize() end,
        read_tile=mount_dependencies.read_tile or
            function(x, y) return dfhack.screen.readTile(x, y) end,
        get_map_view_position=mount_dependencies.get_map_view_position or
            function()
                local global = assert(df and df.global,
                    'DwarfSpec requires df.global for map-view access')
                return global.window_x, global.window_y, global.window_z
            end,
        set_map_view_position=mount_dependencies.set_map_view_position or
            function(x, y, z)
                local global = assert(df and df.global,
                    'DwarfSpec requires df.global for map-view access')
                global.window_x = x
                global.window_y = y
                global.window_z = z
                return true
            end,
        get_map_view_dimensions=
            mount_dependencies.get_map_view_dimensions or function()
                local gui = assert(dfhack and dfhack.gui,
                    'DwarfSpec requires dfhack.gui for map-view dimensions')
                assert(type(gui.getDwarfmodeViewDims) == 'function',
                    'DwarfSpec requires dfhack.gui.getDwarfmodeViewDims')
                return gui.getDwarfmodeViewDims()
        end,
        get_game_enabler=mount_dependencies.get_game_enabler or function()
            return df and df.global and df.global.enabler
        end,
        set_game_speed=mount_dependencies.set_game_speed or
            function(enabler, tps, speed_ratio)
                enabler.fps = tps
                enabler.fps_per_gfps = speed_ratio
                return true
            end,
        map_view_cleanup_entry=nil,
        game_pause_cleanup_entry=nil,
        game_speed_cleanup_entry=nil,
        turbo_speed_cleanup_entry=nil,
    }
    ---Returns recurring-operation ownership for terminal cleanup verification.
    ---@return table
    context.run.unit_speed_cleanup_probe = function()
        local state = recurring_operation:cleanup_state()
        if unit_system then
            local position_state = unit_system.positions:cleanup_state()
            state.unit_position_active = position_state.unit_position_active
            state.owned_position_count = position_state.owned_position_count
        else
            state.unit_position_active = false
            state.owned_position_count = 0
        end
        return state
    end

    local diagnostics = diagnostics_module.new({
        get_window_size=context.get_window_size,
        read_tile=context.read_tile,
    })
    context.diagnostics = diagnostics

    ---Dispatches one native input key through DFHack's GUI module.
    ---@param screen any
    ---@param key string
    ---@return any
    local function simulate_native_input(screen, key)
        return require('gui').simulateInput(screen, key)
    end

    ---Returns the current native main-interface options.
    ---@return any
    local function get_native_options()
        return df.global.game.main_interface.options
    end

    local native_game = {
        is_world_loaded=dfhack.isWorldLoaded,
        read_world_folder=dfhack.world.ReadWorldFolder,
        get_focus=dfhack.gui.getCurFocus,
        current_viewscreen=context.current_viewscreen,
        get_window_size=context.get_window_size,
        simulate_input=simulate_native_input,
        get_options=get_native_options,
        title_screen_type=df.viewscreen_titlest,
        title_mode_type=df.title_mode_type,
        load_screen_type=df.viewscreen_loadgamest,
        main_choice_type=df.main_choice_type,
        main_menu_option_type=df.main_menu_option_type,
    }

    local save_game_unloader =
        mount_dependencies.save_game_unloader or save_game_unload_command.new({
            workflow=save_game_unload_module,
            scheduling=run_capabilities.scheduling,
            wait_settings=wait_settings,
            native_game=native_game,
            pointer_adapter=pointer_adapter_module,
            pointer=context.pointer,
        })

    local rendered_text_search = mount_dependencies.text_search or
        text_search_command.new({
            get_window_size=context.get_window_size,
            read_tile=context.read_tile,
        })

    local await_event = mount_dependencies.await_event or
        await_event_command.new({
            events=EEvent,
            state_changes={
                WORLD_LOADED=SC_WORLD_LOADED,
                WORLD_UNLOADED=SC_WORLD_UNLOADED,
                MAP_LOADED=SC_MAP_LOADED,
                MAP_UNLOADED=SC_MAP_UNLOADED,
                VIEWSCREEN_CHANGED=SC_VIEWSCREEN_CHANGED,
                PAUSED=SC_PAUSED,
                UNPAUSED=SC_UNPAUSED,
            },
            state_change_handlers=dfhack.onStateChange,
            scheduler_module=scheduler_module,
            scheduler=scheduler,
            read_save_directory=function()
                return dfhack.world.ReadWorldFolder()
            end,
            get_focus=function()
                return dfhack.gui.getCurFocus()
            end,
            current_viewscreen=context.current_viewscreen,
        })

    local save_game_loader =
        mount_dependencies.save_game_loader or save_game_load_command.new({
            workflow=save_game_load_module,
            scheduling=run_capabilities.scheduling,
            wait_settings=wait_settings,
            native_game=native_game,
            pointer_adapter=pointer_adapter_module,
            pointer=context.pointer,
            events=EEvent,
            await_event=await_event,
        })
    local publisher = context.run.event_publisher

    ---Publishes one command boundary through the active run generation.
    ---@param event_type DwarfSpecEventType
    ---@param payload table
    local function publish(event_type, payload)
        if publisher then publisher.publish(event_type, payload) end
    end

    ---Returns a stable mounted subject identity.
    ---@param subject table
    ---@return string
    local function command_subject_identity(subject)
        return ('mount:%s/%s'):format(
            tostring(subject.mount_id), tostring(subject.control_path))
    end

    local command_observer = {}

    ---Returns bounded text safe for a structured diagnostic payload.
    ---@param value any
    ---@return string
    local function bounded_text(value)
        local text = tostring(value)
        if #text <= 8192 then return text end
        return text:sub(1, 8189) .. '...'
    end

    ---Publishes one command start and returns its timing identity.
    ---@param name string
    ---@param subject table
    ---@return table
    function command_observer.started(name, subject)
        local started_ms = publisher and publisher.now_ms() or 0
        publish(EventType.COMMAND_STARTED, {
            name=name,
            subject_identity=command_subject_identity(subject),
            safe_arguments={},
        })
        return {
            name=name,
            started_ms=started_ms,
        }
    end

    ---Publishes one command result and bounded failure diagnostics.
    ---@param observation table
    ---@param ok boolean
    ---@param failure any|nil
    function command_observer.finished(observation, ok, failure)
        local finished_ms = publisher and publisher.now_ms() or
            observation.started_ms
        publish(EventType.COMMAND_FINISHED, {
            name=observation.name,
            status=ok and TestStatus.SUCCESS or TestStatus.ERROR,
            duration_ms=math.max(0,
                finished_ms - observation.started_ms),
        })
        if not ok then
            publish(EventType.DIAGNOSTIC_RECORDED, {
                kind='command_failure',
                content={
                    name=observation.name,
                    message=bounded_text(failure),
                },
            })
        end
    end
    command_observer = command_observer_module.new(
        publisher, EventType, TestStatus)
    ---Creates one private render tracker using the run's wait settings.
    ---@return table
    local function new_render_tracker()
        if mount_dependencies.render_tracker_factory then
            return mount_dependencies.render_tracker_factory()
        end
        return render_tracker_module.new(scheduler_module, scheduler, {
            wait_options={
                timeout_ms=wait_settings.timeout_ms,
                frame_budget=wait_settings.frame_budget,
            },
        })
    end
    local boundary = mount_dependencies.boundary
    if not boundary then
        boundary = component_module.new({
            Widget=require('gui.widgets').Widget,
            OverlayWidget=require('plugins.overlay').OverlayWidget,
            ZScreen=require('gui').ZScreen,
        })
    end
    ---Captures and formats one bounded mounted-component failure report.
    ---@param mount table
    ---@param operation string
    ---@param failure any
    ---@return string
    local function report_mount_failure(mount, operation, failure)
        local original = tostring(failure)
        if original:find('DwarfSpec mount failure:', 1, true) then
            return original
        end
        local evidence = diagnostics.capture_mount_failure(
            mount, operation, original)
        context.run.last_mount_diagnostics = evidence
        return diagnostics.format_mount_failure(evidence)
    end
    local adapter_factory = mount_dependencies.adapter_factory
    if not adapter_factory then
        adapter_factory = mount_adapters_module.new({
            instrumentation=render_instrumentation,
            enrich_failure=report_mount_failure,
            overlay_mount_module=overlay_mount_module,
            interaction_target_factory=function(screen)
                return interaction_target_module.new_owned_screen(screen, {
                    is_active=is_active,
                    resolve_native_screen=function(owned_screen)
                        return M.resolve_native_screen(
                            owned_screen, context.current_viewscreen)
                    end,
                })
            end,
            subject_source_factory=lua_view_adapter_module.new_source,
        })
    end
    local is_native_widget_container =
        mount_dependencies.is_native_widget_container
    ---Returns whether one native widget is a child container.
    ---@param widget any
    ---@return boolean
    local function default_is_native_widget_container(widget)
        return df.widget_container:is_instance(widget)
    end
    is_native_widget_container = is_native_widget_container or
        default_is_native_widget_container
    local is_native_widget_root =
        mount_dependencies.is_native_widget_root or
        is_native_widget_container
    local native_widget_identity =
        mount_dependencies.native_widget_identity or
        function(raw) return raw end
    local get_native_widget =
        mount_dependencies.get_native_widget or
        function(parent, segment)
            return dfhack.gui.getWidget(parent, segment)
        end
    local get_native_widget_children =
        mount_dependencies.get_native_widget_children or
        function(parent)
            return dfhack.gui.getWidgetChildren(parent)
        end
    local native_subject_source_factory =
        mount_dependencies.native_subject_source_factory
    if not native_subject_source_factory then
        ---Creates a native source rooted at one exposed DF widget container.
        ---@param root any
        ---@param interaction_target dwarfspec.BorrowedNativeInteractionTarget
        ---@param source_options table|nil
        ---@return dwarfspec.SubjectSource
        local function create_native_subject_source(
                root, interaction_target, source_options)
            source_options = source_options or {}
            return native_widget_adapter_module.new_source(
                root, interaction_target, {
                    get_widget=get_native_widget,
                    get_children=get_native_widget_children,
                    is_container=is_native_widget_container,
                    get_window_size=dfhack.screen.getWindowSize,
                    identity_of=native_widget_identity,
                    root_locator=source_options.root_locator,
                    structural_path=source_options.structural_path,
                })
        end
        native_subject_source_factory=create_native_subject_source
    end
    local native_game_ui_resolver =
        mount_dependencies.native_game_ui_resolver or
        native_game_ui_path_module.new_dfhack({
            df=df,
            get_widget=get_native_widget,
            identity_of=native_widget_identity,
        })
    assert(type(native_game_ui_resolver) == 'table' and
        type(native_game_ui_resolver.has_declared_leading_field) ==
            'function' and
        type(native_game_ui_resolver.resolve) == 'function' and
        type(native_game_ui_resolver.root_locator) == 'function',
        'DwarfSpec requires a complete native game-UI path resolver')
    local native_attachment = mount_dependencies.native_attachment
    if not native_attachment then
        local get_native_viewscreen = mount_dependencies.native_viewscreen or
            function() return dfhack.gui.getDFViewscreen(true) end
        local invalidate_native_screen =
            mount_dependencies.invalidate_native_screen or
            function() return dfhack.screen.invalidate() end
        native_attachment = native_attachment_module.new({
            get_native_viewscreen=get_native_viewscreen,
            is_widget_root=is_native_widget_root,
            interaction_target_factory=function(screen)
                return interaction_target_module.new_borrowed_native(screen, {
                    get_current_viewscreen=context.current_viewscreen,
                    invalidate_screen=invalidate_native_screen,
                })
            end,
            subject_source_factory=native_subject_source_factory,
        })
    end
    assert(type(native_attachment) == 'table' and
        type(native_attachment.attach) == 'function',
        'DwarfSpec requires a native attachment service')
    local overlay_subject_source_factory =
        mount_dependencies.overlay_subject_source_factory
    if overlay_subject_source_factory == nil then
        ---Creates a read-only source from DFHack's live overlay registry.
        ---@param overlay_name string
        ---@return dwarfspec.SubjectSource
        overlay_subject_source_factory = function(overlay_name)
            local overlay = require('plugins.overlay')
            local gui = require('gui')
            assert(type(overlay) == 'table' and
                type(overlay.get_state) == 'function',
                'DFHack overlay registry does not expose get_state()')

            ---Returns whether a registry widget derives from gui.View.
            ---@param value any
            ---@return boolean
            local function is_lua_view(value)
                if type(value) ~= 'table' or
                        type(value.subviews) ~= 'table' then
                    return false
                end
                if type(gui.View) ~= 'table' then return true end
                local class = getmetatable(value)
                while type(class) == 'table' do
                    if class == gui.View then return true end
                    class = rawget(class, 'super')
                end
                return false
            end

            return overlay_registry_adapter_module.new_source(
                overlay_name, {
                    get_state=overlay.get_state,
                    is_lua_view=is_lua_view,
                })
        end
    end
    assert(type(overlay_subject_source_factory) == 'function',
        'DwarfSpec requires an overlay subject source factory')
    local native_render_observer_factory =
        mount_dependencies.native_render_observer_factory
    if native_render_observer_factory == nil then
        ---Observes the real post-native overlay render boundary for one mount.
        ---@param mount table
        ---@return function
        native_render_observer_factory = function(mount)
            local overlay = require('plugins.overlay')
            return native_render_observer_module.install(
                overlay, mount.pinned_screen, mount.render_tracker,
                function(failure)
                    return report_mount_failure(mount, 'render', failure)
                end,
                function()
                    if mount.refresh_views then mount.refresh_views() end
                end)
        end
    end
    assert(type(native_render_observer_factory) == 'function',
        'DwarfSpec requires a native render observer factory')
    context.mount_context = mount_context_module.new({
        run=context.run,
        boundary=boundary,
        cleanup_module=cleanup_module,
        cleanup_registry=cleanup_registry,
        adapter_factory=adapter_factory,
        failure_reporter=mount_dependencies.failure_reporter or
            report_mount_failure,
        render_tracker_factory=new_render_tracker,
        native_render_observer_factory=native_render_observer_factory,
        subject_module=mount_dependencies.subject_module or subject_module,
        command_observer=command_observer,
        testbed_adapter=testbed_adapter_module,
        testbed_host={require=require, reqscript=dfhack.reqscript,
            base=dfhack.BASE_G, dfhack=dfhack},
    })
    local verified_subject_queries
    if command_runner ~= nil then
        assert(type(command_runner.setRefreshRetainedSubjects) == 'function',
            'DwarfSpec command runner requires retained-subject refresh')
        command_runner:setRefreshRetainedSubjects(function()
            local mount = context.mount_context.current
            if mount ~= nil then context.mount_context:refresh_views(mount) end
        end)
    end
    local search_runtime = search_runtime_module.new({
        mount_context=context.mount_context,
        matcher=rendered_text_search,
        text_search=text_search_command,
    })
    context.run.mount_cleanup_probe = function()
        local state = context.mount_context:cleanup_state()
        state.pointer_active =
            pointer_adapter_module.is_active(context.pointer)
        state.button_state_active =
            context.pointer.button_cleanup_entry ~= nil
        state.map_view_position_active =
            context.map_view_cleanup_entry ~= nil
        state.game_pause_state_active =
            context.game_pause_cleanup_entry ~= nil
        state.game_speed_active =
            context.game_speed_cleanup_entry ~= nil
        state.turbo_speed_active =
            context.turbo_speed_cleanup_entry ~= nil
        state.render_observer_active =
            context.mount_context.current ~= nil and
            context.mount_context.current.render_observer ~= nil
        return state
    end
    local overlay_registration =
        overlay_registration_module.new(run_capabilities)
    local overlay_transaction = command_runner and
        overlay_registration_module.new_transaction(run_capabilities) or nil

    ---Stages one real overlay-registration source through run-owned cleanup.
    ---@param source_path string
    ---@param logical_name string
    ---@return table
    local function stage_overlay_registration_integration(
            source_path, logical_name)
        return overlay_registration.stage(source_path, logical_name)
    end
    context.run.overlay_registration_integration =
        stage_overlay_registration_integration
    local ds = {
        protocol_version=1,
        EMouseButton=EMouseButton,
        EInputState=EInputState,
        EPointerSpace=EPointerSpace,
        EPointerAnchor=EPointerAnchor,
        EScreenOrigin=EScreenOrigin,
        ESubjectSource=ESubjectSource,
        EEvent=EEvent,
    }

    local register_cleanup_options
    if command_runner ~= nil then
        local cleanup_service = assert(context.run.cleanup_registration_service,
            'DwarfSpec requires the run cleanup registration service')
        local resource_index = assert(context.run.resource_dependency_index,
            'DwarfSpec requires the run resource dependency index')
        register_cleanup_options = {
            freeze_registrations=function(registrations)
                return resource_index:freeze_registrations(registrations)
            end,
            assert_registration_open=function(owner)
                return cleanup_service:assertRegistrationOpen(owner)
            end,
            verify_registration=function(transaction_id, owner)
                return cleanup_service:verifyRegistration(transaction_id, owner)
            end,
            wrap_handle=function(transaction, owner)
                return cleanup_handle.new(transaction, owner, function()
                    return context.run.cleanup_owner_lifecycle:public_owner()
                end, function(expected)
                    command_runner:assertHandleExecution(expected)
                end)
            end,
        }
    end

    ---Resolves a subject or omitted target against the implicit mount.
    ---@param value any
    ---@param operation string
    ---@return any, dwarfspec.OwnedScreenInteractionTarget|dwarfspec.BorrowedNativeInteractionTarget|nil, table|nil, dwarfspec.SubjectAdapter|nil
    local interaction_target_resolver =
        interaction_target_resolver_module.new(context.mount_context)

    ---Dispatches simulated input through the current mount's input ingress.
    ---@param target dwarfspec.OwnedScreenInteractionTarget|dwarfspec.BorrowedNativeInteractionTarget
    ---@param operation string
    ---@param keys string|table|nil
    ---@return any
    local function simulate_input(target, operation, keys)
        local input_screen = target:input_screen(operation)
        assert(input_screen ~= nil,
            ('DwarfSpec %s requires an input viewscreen'):format(operation))
        return require('gui').simulateInput(input_screen, keys)
    end

    ---Resolves and registers one explicit source for a native-screen mount.
    ---@param mount table
    ---@param request dwarfspec.SubjectSourceRequest
    ---@return dwarfspec.SubjectSource
    local function select_subject_source(mount, request)
        assert(mount.subject_source.kind == ESubjectSource.NATIVE,
            'component mounts do not accept subject source options')
        if request.source == ESubjectSource.NATIVE then
            if request.native_root == nil then return mount.subject_source end
            local root_ok, is_root = pcall(
                is_native_widget_root, request.native_root)
            assert(root_ok and is_root,
                'native_root must be a DF widget_container exposed by DFHack')
            for source in pairs(mount.subject_sources) do
                if source.kind == ESubjectSource.NATIVE and
                        source.adapter:root() == request.native_root then
                    return source
                end
            end
            local source = native_subject_source_factory(
                request.native_root, mount.interaction_target)
            assert(type(source) == 'table' and
                source.kind == ESubjectSource.NATIVE and
                source.adapter:root() == request.native_root,
                'native subject source factory returned an invalid source')
            return context.mount_context:register_subject_source(source)
        end
        local source = overlay_subject_source_factory(request.overlay)
        assert(type(source) == 'table' and
            source.kind == ESubjectSource.OVERLAY and
            source.overlay == request.overlay,
            'overlay subject source factory returned an invalid source')
        return context.mount_context:register_subject_source(source)
    end

    ---Attempts one path against an already registered subject source.
    ---@param source dwarfspec.SubjectSource
    ---@param path_segments dwarfspec.NativePath
    ---@param diagnostic_path string
    ---@return table
    local function attempt_source_path(
            source, path_segments, diagnostic_path)
        local ok, result = pcall(function()
            local view = context.mount_context:resolve_path_segments(
                path_segments, diagnostic_path, source)
            local root = source.adapter:root()
            return {
                view=view,
                identity=source.adapter:identity(view),
                type=source.adapter:native_type(view),
                root_identity=source.adapter:captured_root_identity(),
                root_type=source.adapter:native_type(root),
            }
        end)
        if ok then
            result.success = true
            result.source = source
            result.path_segments = path_segments
            return result
        end
        return {
            success=false,
            failure=tostring(result),
        }
    end

    ---Formats a failed game-UI result with optional native child evidence.
    ---@param mount table
    ---@param resolution dwarfspec.GameUIPathResolution
    ---@param diagnostic_path string
    ---@return string
    local function format_game_ui_failure(
            mount, resolution, diagnostic_path)
        local original =
            native_game_ui_path_module.format_failure(resolution)
        if resolution.failure.stage ~=
                EResolutionStage.WIDGET_TRAVERSAL or
                resolution.widget_root == nil or
                #resolution.structural_segments == 0 then
            return original
        end

        local source
        local capture_ok, captured = pcall(function()
            source = native_subject_source_factory(
                resolution.widget_root, mount.interaction_target, {
                    root_locator=native_game_ui_resolver:root_locator(
                        resolution.structural_segments),
                    structural_path=resolution.structural_segments,
                })
            local _, failure =
                source.adapter:resolve(resolution.widget_segments)
            assert(failure,
                'game-UI diagnostic lookup unexpectedly succeeded')
            return source.adapter:format_resolution_failure(
                failure, resolution.widget_segments, diagnostic_path)
        end)
        if source and source.adapter and
                type(source.adapter.cleanup) == 'function' then
            pcall(source.adapter.cleanup, source.adapter)
        end
        if capture_ok then return captured end
        return original .. '; diagnostic_capture_failed=true'
    end

    ---Creates or reuses a located source for one game-UI resolution.
    ---@param mount table
    ---@param resolution dwarfspec.GameUIPathResolution
    ---@param diagnostic_path string
    ---@return table
    local function select_game_ui_result(
            mount, resolution, diagnostic_path)
        local source = native_subject_source_factory(
            resolution.widget_root, mount.interaction_target, {
                root_locator=native_game_ui_resolver:root_locator(
                    resolution.structural_segments),
                structural_path=resolution.structural_segments,
            })
        assert(type(source) == 'table' and
            source.kind == ESubjectSource.NATIVE,
            'native game-UI source factory returned an invalid source')
        source = context.mount_context:register_subject_source(source)
        local selected = attempt_source_path(
            source, resolution.widget_segments, diagnostic_path)
        assert(selected.success,
            'native game-UI widget suffix changed during selection: ' ..
                tostring(selected.failure))
        assert(selected.identity == resolution.widget_identity,
            'native game-UI widget identity changed during selection')
        return selected
    end

    ---Resolves one implicit native request across both compatible roots.
    ---@param mount table
    ---@param path_segments dwarfspec.NativePath
    ---@param diagnostic_path string
    ---@return table
    local function resolve_implicit_native_path(
            mount, path_segments, diagnostic_path)
        local viewscreen = attempt_source_path(
            mount.subject_source, path_segments, diagnostic_path)
        local eligibility_ok, eligible = pcall(
            native_game_ui_resolver.has_declared_leading_field,
            native_game_ui_resolver, path_segments)
        if not eligibility_ok or not eligible then
            if viewscreen.success then return viewscreen end
            error(viewscreen.failure, 0)
        end

        local game_ok, game_resolution = pcall(
            native_game_ui_resolver.resolve,
            native_game_ui_resolver, path_segments)
        local game_success = game_ok and
            type(game_resolution) == 'table' and
            game_resolution.failure == nil and
            game_resolution.widget ~= nil and
            game_resolution.widget_identity ~= nil
        if viewscreen.success and game_success then
            if viewscreen.identity == game_resolution.widget_identity then
                return viewscreen
            end
            error(('DwarfSpec get failed: stage=%s native_path=%s is ' ..
                'ambiguous; viewscreen={root_type=%q root_identity=%s ' ..
                'widget_type=%q widget_identity=%s}; ' ..
                'game_ui={root_type=%q root_identity=%s widget_type=%q ' ..
                'widget_identity=%s}'):format(
                    EResolutionStage.AMBIGUITY_CHECK,
                    diagnostic_path,
                    viewscreen.root_type,
                    identity_labels.of(viewscreen.root_identity),
                    viewscreen.type,
                    identity_labels.of(viewscreen.identity),
                    game_resolution.widget_root_type,
                    identity_labels.of(
                        game_resolution.widget_root_identity),
                    game_resolution.widget_type,
                    identity_labels.of(
                        game_resolution.widget_identity)), 0)
        end
        if viewscreen.success then return viewscreen end
        if game_success then
            return select_game_ui_result(
                mount, game_resolution, diagnostic_path)
        end

        local game_failure
        if not game_ok then
            game_failure = bounded_text(game_resolution)
        elseif type(game_resolution) == 'table' and
                game_resolution.failure then
            game_failure = format_game_ui_failure(
                mount, game_resolution, diagnostic_path)
        else
            game_failure = 'invalid game-UI resolver result'
        end
        error(('DwarfSpec get failed: stage=%s native_path=%s was ' ..
            'unavailable from ' ..
            'both native roots; viewscreen={%s}; game_ui={%s}'):format(
                EResolutionStage.AMBIGUITY_CHECK,
                diagnostic_path, bounded_text(viewscreen.failure),
                bounded_text(game_failure)), 0)
    end

    local native_subject_sources = native_subject_source_module.new({
        sources=ESubjectSource,
        mount_context=context.mount_context,
        is_native_widget_root=is_native_widget_root,
        native_factory=native_subject_source_factory,
        overlay_factory=overlay_subject_source_factory,
        resolve_implicit_path=resolve_implicit_native_path,
    })

    ---Restores all currently registered test-owned resources.
    local function reset(reason)
        reason = reason or 'automation lifecycle'
        local ok, failures = cleanup_module.run_from(cleanup_registry,
            example_cleanup_marker, reason)
        local wait_ok, wait_error = xpcall(function()
            scheduler_module.wait_frames(scheduler, 1, {
                description='wait for automation cleanup',
            })
        end, debug.traceback)
        local messages = {}
        for _, failure in ipairs(failures) do
            failure.reported_by_busted = true
            table.insert(messages, failure.name .. ': ' .. failure.message)
        end
        if not wait_ok then
            table.insert(messages, 'settle wait: ' .. tostring(wait_error))
        end
        if not ok or not wait_ok then
            context.run.cleanup_failure_reported_by_busted = not ok
            error('automation cleanup failed during ' .. reason .. ': ' ..
                table.concat(messages, '; '), 2)
        end
    end

    ---Sets the game pause state for the current example.
    ---DwarfSpec automatically restores the inherited state during cleanup.
    ---@param paused boolean
    ---@return boolean
    function ds.setGamePaused(paused)
        assert(type(paused) == 'boolean',
            'game pause state must be a boolean')
        if context.game_pause_cleanup_entry == nil then
            local original = ds.isGamePaused()
            context.game_pause_cleanup_entry = cleanup_module.push(
                cleanup_registry, 'restore game pause state', function()
                    local global = df and df.global
                    assert(global ~= nil,
                        'DwarfSpec could not restore game pause state: ' ..
                            'df.global is unavailable')
                    global.pause_state = original
                    assert(global.pause_state == original,
                        'DFHack rejected the original game pause state')
                    context.game_pause_cleanup_entry = nil
                end)
        end
        local global = df and df.global
        assert(global ~= nil,
            'DwarfSpec could not set game pause state: ' ..
                'df.global is unavailable')
        global.pause_state = paused
        assert(global.pause_state == paused,
            'DFHack rejected the requested game pause state')
        return paused
    end

    ---Discards the loaded save and waits for the native title main menu.
    ---An already-visible title main menu is an idempotent no-op. The resulting
    ---state is not cleanup-owned and remains in effect for later examples.
    ---@param ... any
    ---@return string|nil
    function ds.exitToMainMenu(...)
        assert(select('#', ...) == 0,
            'DwarfSpec exitToMainMenu does not accept arguments')
        return save_game_unloader:exit_to_main_menu()
    end

    ---Returns the validated current map-view dimensions.
    ---@return table
    local function current_map_view_dimensions()
        local ok, dimensions = pcall(context.get_map_view_dimensions)
        assert(ok,
            'DwarfSpec could not query the current map-view dimensions: ' ..
                tostring(dimensions))
        assert(type(dimensions) == 'table',
            'DFHack returned invalid map-view dimensions')
        for _, field in ipairs({'map_x1', 'map_x2', 'map_y1', 'map_y2'}) do
            local value = dimensions[field]
            assert(type(value) == 'number' and value % 1 == 0,
                'DFHack returned invalid map-view dimensions')
        end
        local width = dimensions.map_x2 - dimensions.map_x1 + 1
        local height = dimensions.map_y2 - dimensions.map_y1 + 1
        assert(width > 0 and height > 0,
            'DFHack returned invalid map-view dimensions')
        return dimensions, width, height
    end

    ---Mounts one owned component or complete screen.
    ---DwarfSpec automatically unmounts it during example cleanup.
    ---@param component any
    ---@param options table|nil
    ---@return table
    function ds.mount(component, options)
        assert(component ~= nil,
            'DwarfSpec ds.mount() requires a component; use ' ..
                'ds.mountNativeScreen() to mount the current native DF screen')
        return context.mount_context:mount(component, options)
    end

    ---Mounts the current native DF screen without taking ownership of it.
    ---DwarfSpec automatically detaches the mount during example cleanup.
    ---@param ... any
    ---@return table
    function ds.mountNativeScreen(...)
        assert(select('#', ...) == 0,
            'DwarfSpec ds.mountNativeScreen() does not accept arguments')
        return context.mount_context:mount_native_screen(function()
            return native_attachment:attach()
        end)
    end

    ---Releases the current native attachment or mounted component.
    function ds.unmount()
        return context.mount_context:unmount()
    end

    ---Returns a copied focus-string list for one current mounted subject.
    ---@param subject table
    ---@return string[]
    local function get_focus_list(subject)
        local interaction_target
        _, interaction_target = interaction_target_resolver:resolve(subject,
            'getFocusList')
        local gui = dfhack and dfhack.gui
        assert(type(gui) == 'table' and
                type(gui.getFocusStrings) == 'function',
            'DwarfSpec getFocusList requires dfhack.gui.getFocusStrings')
        local focus_list = gui.getFocusStrings(
            interaction_target:native_screen('getFocusList'))
        assert(type(focus_list) == 'table',
            'DFHack getFocusStrings did not return a focus list')
        local result = {}
        for index, focus in ipairs(focus_list) do
            assert(type(focus) == 'string',
                'DFHack getFocusStrings returned a non-string focus value')
            result[index] = focus
        end
        return result
    end

    ---Invalidates a subject's mounted screen and waits by default.
    ---@param view table|nil Defaults to the current source root.
    ---@param options table|nil
    ---@return any
    function ds.redraw(view, options)
        local interaction_target
        _, interaction_target = interaction_target_resolver:resolve(
            view, 'redraw')
        assert(type(options) == 'table' or options == nil,
            'redraw options must be a table')
        options = options or {}
        for name in pairs(options) do
            assert(name == 'wait',
                'unsupported redraw option: ' .. tostring(name))
        end
        assert(options.wait == nil or type(options.wait) == 'boolean',
            'redraw wait option must be a boolean')
        return context.mount_context:mutate('redraw', function()
            return interaction_target:invalidate()
        end, {
            wait_for_render=options.wait ~= false,
        })
    end

    ---Formats one rectangle without inspecting arbitrary adapted fields.
    ---@param rect table|nil
    ---@return string
    local function format_pointer_rect(rect)
        if type(rect) ~= 'table' then return '<unavailable>' end
        return ('{x1=%s,y1=%s,x2=%s,y2=%s}'):format(
            tostring(rect.x1), tostring(rect.y1),
            tostring(rect.x2), tostring(rect.y2))
    end

    ---Returns the current positive integral native window dimensions.
    ---@param target dwarfspec.OwnedScreenInteractionTarget|dwarfspec.BorrowedNativeInteractionTarget
    ---@param operation string
    ---@return integer, integer
    local function current_window_size(target, operation)
        target:native_screen(operation)
        local ok, width, height = pcall(context.get_window_size)
        target:native_screen(operation)
        assert(ok, ('DwarfSpec %s could not query the current window: %s')
            :format(operation, tostring(width)))
        assert(type(width) == 'number' and width % 1 == 0 and width > 0 and
                type(height) == 'number' and height % 1 == 0 and height > 0,
            ('DwarfSpec %s received invalid current window dimensions: ' ..
                'width=%s height=%s'):format(operation, tostring(width),
                    tostring(height)))
        return width, height
    end

    ---Returns bounded diagnostics for one pointer subject or source root.
    ---@param requested_subject table|nil
    ---@param source dwarfspec.SubjectSource
    ---@param adapter dwarfspec.SubjectAdapter
    ---@param view any
    ---@param bounds table|nil
    ---@return string
    local function pointer_subject_diagnostics(requested_subject, source,
            adapter, view, bounds)
        local descriptor = requested_subject and
            requested_subject._descriptor or nil
        local path = descriptor and
            descriptor.control_path_for_diagnostics or '<root>'
        local ok, native_type = pcall(adapter.native_type, adapter, view)
        if not ok then native_type = '<unavailable>' end
        local source_name = source.kind
        if source.overlay then
            source_name = source_name .. ':' .. source.overlay
        end
        return ('source=%q path=%q native_type=%q bounds=%s'):format(
            tostring(source_name), tostring(path), tostring(native_type),
            format_pointer_rect(bounds))
    end

    ---Clips normalized inclusive subject bounds to the current window.
    ---@param bounds table|nil
    ---@param width integer
    ---@param height integer
    ---@return table|nil
    local function clip_pointer_bounds(bounds, width, height)
        if type(bounds) ~= 'table' then return nil end
        for _, field in ipairs({'x1', 'y1', 'x2', 'y2'}) do
            local value = bounds[field]
            if type(value) ~= 'number' or value % 1 ~= 0 then return nil end
        end
        local clipped = {
            x1=math.max(0, bounds.x1),
            y1=math.max(0, bounds.y1),
            x2=math.min(width - 1, bounds.x2),
            y2=math.min(height - 1, bounds.y2),
        }
        if clipped.x1 > clipped.x2 or clipped.y1 > clipped.y2 then return nil end
        return clipped
    end

    ---Runs one pointer mutation and reapplies paired raw state after rendering.
    ---@param operation string
    ---@param action function
    ---@return any
    local function mutate_pointer(operation, action)
        local results = table.pack(
            context.mount_context:mutate(operation, action))
        pointer_adapter_module.sync(context.pointer)
        return table.unpack(results, 1, results.n)
    end

    ---Normalizes and applies one pointer coordinate pair.
    ---@param x any
    ---@param y any
    ---@param space DwarfSpecEPointerSpace
    local function set_pointer_coordinates(x, y, space)
        local geometry = pointer_adapter_module.geometry(context.pointer)
        local position = pointer_adapter_module.normalize_position(
            x, y, space, geometry)
        mutate_pointer('move_pointer', function()
            pointer_adapter_module.set(context.pointer, position)
        end)
    end

    ---Moves the virtual pointer to one UI-grid cell.
    ---@param x any
    ---@param y any
    ---@return integer, integer
    local function move_pointer_to_grid(x, y)
        local target
        _, target = interaction_target_resolver:resolve(nil, 'move_pointer')
        assert(type(x) == 'number' and x % 1 == 0 and x >= 0,
            'pointer x coordinate must be a nonnegative integer')
        assert(type(y) == 'number' and y % 1 == 0 and y >= 0,
            'pointer y coordinate must be a nonnegative integer')
        local width, height = current_window_size(target, 'move_pointer')
        assert(x < width,
            ('pointer x coordinate %d is outside the current window width %d')
                :format(x, width))
        assert(y < height,
            ('pointer y coordinate %d is outside the current window height %d')
                :format(y, height))
        mutate_pointer('move_pointer', function()
            pointer_adapter_module.set_grid(context.pointer, x, y)
        end)
        return x, y
    end

    ---Moves the virtual pointer to one exact screen pixel.
    ---@param x any
    ---@param y any
    ---@return integer, integer
    local function move_pointer_to_pixels(x, y)
        interaction_target_resolver:resolve(nil, 'move_pointer')
        set_pointer_coordinates(x, y, EPointerSpace.PIXELS)
        return x, y
    end

    ---Validates and copies one requested world-tile position.
    ---@param position table
    ---@return table
    local function validate_world_tile_position(position)
        assert(type(position) == 'table',
            'world-tile position must be a table with x, y, and z coordinates')
        local validated = {}
        for _, axis in ipairs({'x', 'y', 'z'}) do
            local value = position[axis]
            assert(type(value) == 'number' and value % 1 == 0 and value >= 0,
                ('world-tile %s coordinate must be a nonnegative integer')
                    :format(axis))
            validated[axis] = value
        end
        return validated
    end

    ---Moves the virtual pointer to one visible world tile.
    ---@param requested_position table
    ---@param options table|nil
    ---@return integer, integer, integer
    local function move_pointer_to_world_tile(requested_position, options)
        local position = validate_world_tile_position(requested_position)
        assert(options == nil or type(options) == 'table',
            'world-tile pointer options must be a table')
        options = options or {}
        assert(options.recenter == nil or type(options.recenter) == 'boolean',
            'world-tile pointer recenter option must be a boolean')
        local recenter = options.recenter ~= false
        interaction_target_resolver:resolve(nil, 'move_pointer')
        mutate_pointer('move_pointer', function()
            if recenter then
                ds.setViewPos(position, EScreenOrigin.CENTER)
            end
            local dimensions = current_map_view_dimensions()
            local view_position = ds.getViewPos(EScreenOrigin.TOP_LEFT)
            assert(position.z == view_position.z,
                ('world tile z coordinate %d is not on the visible z-level %d')
                    :format(position.z, view_position.z))
            local x = position.x - view_position.x
            local y = position.y - view_position.y
            local width = dimensions.map_x2 - dimensions.map_x1 + 1
            local height = dimensions.map_y2 - dimensions.map_y1 + 1
            assert(x >= 0 and x < width and y >= 0 and y < height,
                ('world tile (%d, %d, %d) is outside the current map view')
                    :format(position.x, position.y, position.z))
            local geometry = pointer_adapter_module.geometry(context.pointer)
            local pointer_space = EPointerSpace.GRID
            local in_graphics_mode = pointer_screen.inGraphicsMode
            if type(in_graphics_mode) == 'function' and
                    in_graphics_mode() then
                local zoom = pointer_gps.viewport_zoom_factor
                assert(type(zoom) == 'number' and zoom % 1 == 0 and
                        zoom >= 4,
                    'DFHack returned an invalid viewport zoom factor')
                local map_tile_pixels = math.floor(zoom / 4)
                x = x * map_tile_pixels + math.floor(map_tile_pixels / 2)
                y = y * map_tile_pixels + math.floor(map_tile_pixels / 2)
                pointer_space = EPointerSpace.PIXELS
            end
            local pointer_position = pointer_adapter_module.normalize_position(
                x, y, pointer_space, geometry)
            pointer_adapter_module.set(context.pointer, pointer_position)
        end)
        return position.x, position.y, position.z
    end

    ---Returns the UI-grid coordinate selected by one subject anchor.
    ---@param bounds table
    ---@param anchor DwarfSpecEPointerAnchor|nil
    ---@return integer, integer
    local function pointer_anchor_coordinates(bounds, anchor)
        anchor = anchor or EPointerAnchor.CENTER
        if anchor == EPointerAnchor.TOP_LEFT then
            return bounds.x1, bounds.y1
        end
        if anchor == EPointerAnchor.TOP_RIGHT then
            return bounds.x2, bounds.y1
        end
        if anchor == EPointerAnchor.BOTTOM_LEFT then
            return bounds.x1, bounds.y2
        end
        if anchor == EPointerAnchor.BOTTOM_RIGHT then
            return bounds.x2, bounds.y2
        end
        assert(anchor == EPointerAnchor.CENTER,
            'unsupported pointer anchor: ' .. anchor)
        return math.floor((bounds.x1 + bounds.x2) / 2),
            math.floor((bounds.y1 + bounds.y2) / 2)
    end

    ---Moves the virtual pointer to one anchor within a live subject.
    ---@param requested_subject table|nil
    ---@param anchor DwarfSpecEPointerAnchor|nil
    ---@return integer, integer
    local function move_pointer_to_subject(requested_subject, anchor)
        local view
        local target
        local mount
        local adapter
        view, target, mount, adapter = interaction_target_resolver:resolve(
            requested_subject, 'move_pointer')
        local source = requested_subject and
            requested_subject._descriptor.source or mount.subject_source
        local raw_bounds = adapter:bounds(view)
        local body = raw_bounds
        if type(adapter.interaction_bounds) == 'function' then
            body = adapter:interaction_bounds(view)
        end
        local width, height = current_window_size(target, 'move_pointer')
        body = clip_pointer_bounds(body, width, height)
        assert(body, 'DwarfSpec pointer placement failed: ' ..
            pointer_subject_diagnostics(requested_subject, source, adapter,
                view, raw_bounds) ..
            ' reason="no usable live bounds within the current window"')
        local x, y = pointer_anchor_coordinates(body, anchor)
        mutate_pointer('move_pointer', function()
            local geometry = pointer_adapter_module.geometry(context.pointer)
            local position = pointer_adapter_module.normalize_position(
                x, y, EPointerSpace.GRID, geometry)
            pointer_adapter_module.set(context.pointer, position)
        end)
        return x, y
    end

    ---Moves the virtual pointer to coordinates or an anchor inside a subject.
    ---DwarfSpec automatically restores inherited pointer state during cleanup.
    ---@overload fun(x: integer, y: integer, space: DwarfSpecEPointerSpace|nil): integer, integer
    ---@overload fun(position: table, space: DwarfSpecEPointerSpace, options: table|nil): integer, integer, integer
    ---@param view table|integer|nil
    ---@param anchor DwarfSpecEPointerAnchor|integer|DwarfSpecEPointerSpace|nil
    ---@param space DwarfSpecEPointerSpace|table|nil
    ---@return integer, integer
    function ds.move_pointer(view, anchor, space)
        if type(view) == 'table' and
                anchor == EPointerSpace.WORLD_TILE then
            return move_pointer_to_world_tile(view, space)
        end
        local explicit_space = space ~= nil
        if explicit_space and
                (type(view) == 'table' or view == nil) then
            error('pointer coordinate space is only valid with numeric ' ..
                'coordinates', 2)
        end
        if type(view) == 'number' or explicit_space then
            local x = view
            local y = anchor
            space = space or EPointerSpace.GRID
            if space == EPointerSpace.GRID then
                return move_pointer_to_grid(x, y)
            end
            if space == EPointerSpace.PIXELS then
                return move_pointer_to_pixels(x, y)
            end
            error('unsupported pointer coordinate space: ' .. tostring(space),
                2)
        end
        return move_pointer_to_subject(view, anchor)
    end

    ---Moves the virtual pointer over a subject and waits for its render.
    ---DwarfSpec automatically restores inherited pointer state during cleanup.
    ---@param view table|integer|nil
    ---@param anchor DwarfSpecEPointerAnchor|integer|nil
    ---@param space DwarfSpecEPointerSpace|nil
    ---@return integer, integer
    function ds.hover(view, anchor, space)
        return ds.move_pointer(view, anchor, space)
    end

    ---Sends supported native input and waits for the live screen to settle.
    ---@param keys string|table
    ---@param subject table|nil
    ---@return integer
    function ds.input(keys, subject)
        local interaction_target
        _, interaction_target = interaction_target_resolver:resolve(
            subject, 'input')
        return context.mount_context:mutate('input', function()
            simulate_input(interaction_target, 'input', keys)
        end)
    end

    local mouse_button_fields = {
        [EMouseButton.LEFT]={
            click_key='_MOUSE_L',
            down_key='_MOUSE_L_DOWN',
            down_field='mouse_lbut_down',
            lift_field='mouse_lbut_lift',
        },
        [EMouseButton.RIGHT]={
            click_key='_MOUSE_R',
            down_key='_MOUSE_R_DOWN',
            down_field='mouse_rbut_down',
            lift_field='mouse_rbut_lift',
        },
        [EMouseButton.MIDDLE]={
            click_key='_MOUSE_M',
            down_key='_MOUSE_M_DOWN',
            down_field='mouse_mbut_down',
            lift_field='mouse_mbut_lift',
        },
    }
    local mouse_wheel_keys = {
        [EMouseButton.SCROLL_UP]='CONTEXT_SCROLL_UP',
        [EMouseButton.SCROLL_DOWN]='CONTEXT_SCROLL_DOWN',
    }

    ---Validates options for a batch of discrete mouse-wheel inputs.
    ---@param options table
    ---@return DwarfSpecEMouseButton, integer, string|nil
    local function normalize_mouse_wheel_options(options)
        assert(type(options) == 'table',
            'mouseWheel options must be a table')
        for name in pairs(options) do
            assert(name == 'direction' or name == 'steps' or name == 'anchor',
                'unsupported mouseWheel option: ' .. tostring(name))
        end
        local key = mouse_wheel_keys[options.direction]
        assert(key, 'mouseWheel direction must be SCROLL_UP or SCROLL_DOWN')
        local steps = options.steps or 1
        assert(type(steps) == 'number' and steps > 0 and steps % 1 == 0,
            'mouseWheel steps must be a positive integer')
        assert(options.anchor == nil or type(options.anchor) == 'string',
            'mouseWheel anchor must be a string')
        return options.direction, steps, options.anchor
    end

    ---Sends one mouse action at the current virtual pointer position.
    ---DwarfSpec automatically restores persistent button state during cleanup.
    ---@param button DwarfSpecEMouseButton
    ---@param action DwarfSpecEInputState|nil
    ---@return integer
    function ds.mouseInput(button, action)
        local interaction_target
        _, interaction_target = interaction_target_resolver:resolve(
            nil, 'mouseInput')
        local fields = mouse_button_fields[button]
        local key = mouse_wheel_keys[button]
        assert(fields or key,
            'unsupported mouse button: ' .. tostring(button))
        if fields then
            action = action or EInputState.CLICK
            assert(action == EInputState.CLICK or
                    action == EInputState.DOWN or
                    action == EInputState.UP,
                'unsupported mouse button action: ' .. tostring(action))
            if action == EInputState.CLICK then
                key = fields.click_key
            elseif action == EInputState.DOWN then
                key = fields.down_key
            end
        else
            assert(action == nil,
                'mouse wheel input does not accept a button action')
        end
        pointer_adapter_module.position(context.pointer)
        return mutate_pointer('mouseInput', function()
            local dispatch = function()
                pointer_adapter_module.sync(context.pointer)
                simulate_input(interaction_target, 'mouse input', key)
            end
            if not fields or action == EInputState.CLICK then
                pointer_adapter_module.with_mouse_focus(
                    context.pointer, dispatch)
            else
                pointer_adapter_module.with_button_state(
                    context.pointer,
                    fields.down_field,
                    fields.lift_field,
                    action == EInputState.DOWN,
                    dispatch)
            end
        end)
    end

    ---Sends a batch of discrete wheel inputs at the current virtual pointer.
    ---Only the render after the complete batch is awaited.
    ---@param options table
    ---@param subject table|nil
    ---@return integer
    function ds.mouseWheel(options, subject)
        local direction, steps, anchor = normalize_mouse_wheel_options(options)
        assert(subject ~= nil or anchor == nil,
            'mouseWheel anchor requires a subject')
        if subject then ds.hover(subject, anchor) end
        local interaction_target
        _, interaction_target = interaction_target_resolver:resolve(
            subject, 'mouseWheel')
        local key = mouse_wheel_keys[direction]
        pointer_adapter_module.position(context.pointer)
        return mutate_pointer('mouseWheel', function()
            pointer_adapter_module.with_mouse_focus(context.pointer, function()
                for _ = 1, steps do
                    pointer_adapter_module.sync(context.pointer)
                    simulate_input(interaction_target, 'mouse wheel', key)
                end
            end)
        end)
    end

    ---Types ASCII text through DFHack's supported string keycodes.
    ---@param text string
    ---@param subject table|nil
    ---@return integer
    function ds.type(text, subject)
        local interaction_target
        _, interaction_target = interaction_target_resolver:resolve(
            subject, 'type')
        return context.mount_context:mutate('type', function()
            assert(type(text) == 'string', 'text input must be a string')
            for index = 1, #text do
                assert(text:byte(index) >= 1,
                    'text input cannot contain NUL bytes')
                simulate_input(interaction_target, 'type',
                    ('STRING_A%03d'):format(text:byte(index)))
            end
        end)
    end

    ---Changes the current mounted component viewport and waits for its render.
    ---The viewport remains mount-scoped and ends with DwarfSpec's automatic
    ---unmount cleanup.
    ---@param width integer
    ---@param height integer
    function ds.viewport(width, height)
        return context.mount_context:viewport(width, height)
    end

    game_state_command.bind(ds, {
        context=context,
        cleanup_module=cleanup_module,
        cleanup_registry=cleanup_registry,
    })
    unit_speed_command.bind(ds, {controller={
        ---Activates the shared run-owned unit-speed controller.
        ---@param _ table
        ---@param options table
        activate=function(_, options)
            get_unit_system().speed:activate(options)
        end,
    }})
    unit_position_command.bind(ds, {position_controller={
        ---Moves a unit through the shared run-owned position controller.
        ---@param _ table
        ---@param unit_id integer
        ---@param position table
        ---@return boolean
        move=function(_, unit_id, position)
            return get_unit_system().positions:move(unit_id, position)
        end,
    }})
    local mount_commands = mount_command.new({
        context=context,
        native_attachment=native_attachment,
        resolve_target=function(value, operation)
            return interaction_target_resolver:resolve(value, operation)
        end,
    })
    for _, name in ipairs({'mount', 'mountNativeScreen', 'unmount', 'redraw',
            'viewport'}) do
        ds[name] = mount_commands[name]
    end
    local input_commands = input_command.new({
        context=context,
        resolve_target=function(value, operation)
            return interaction_target_resolver:resolve(value, operation)
        end,
        simulate_input=simulate_input,
    })
    ds.input = input_commands.input
    ds.type = input_commands.type
    if command_runner ~= nil then
        assert(type(command_runner.setRuntimeDependencies) == 'function',
            'DwarfSpec command runner requires runtime dependency composition')
        local wait_runtime = wait_runtime_module.new({
            scheduler_module=scheduler_module, scheduler=scheduler,
            await_event=await_event,
            wait_until=run_capabilities.scheduling.wait_until,
        })
        command_runner:setRuntimeDependencies({
            wait=function(remaining_ms)
                return run_capabilities.scheduling.wait_frames(1, {
                    timeout_ms=remaining_ms,
                    description='verified command scheduler step',
                })
            end,
            resolve_mount=function()
                return context.mount_context:require_current('command')
            end,
            resolve_target=function(target)
                return context.mount_context:resolve_subject(target, 'command')
            end,
            lookup_claim=function(reference)
                return context.run.resource_dependency_index:lookup(reference)
            end,
            capture_render=function()
                local mount = context.mount_context:require_current('command')
                return mount.render_tracker:capture()
            end,
            observe_render=function(generation)
                local mount = context.mount_context:require_current('command')
                return mount.render_tracker:generation() > generation
            end,
            wait_frames=function(count, options, remaining_ms)
                return wait_runtime:wait_frames(count, options, remaining_ms)
            end,
            wait_ticks=function(count, options, remaining_ms)
                return wait_runtime:wait_ticks(count, options, remaining_ms)
            end,
            wait_event=function(event, options, remaining_ms)
                return wait_runtime:wait_event(event, options, remaining_ms)
            end,
            wait_until=function(description, query, options, remaining_ms)
                return wait_runtime:wait_until(description, query, options,
                    remaining_ms)
            end,
        })

        local click_runtime = click_runtime_module.new({
            resolver=interaction_target_resolver,
            move_pointer=ds.move_pointer,
            mutate=mutate_pointer,
            pointer=context.pointer,
            pointer_adapter=pointer_adapter_module,
            simulate_input=simulate_input,
        })
        local map_view_runtime = map_view_runtime_module.new({
            read=context.get_map_view_position,
            write=context.set_map_view_position,
            dimensions=context.get_map_view_dimensions,
            origins=EScreenOrigin,
        })
        local save_game_runtime = save_game_runtime_module.new({
            loader=save_game_loader,
            unloader=save_game_unloader,
            host={is_world_loaded=dfhack.isWorldLoaded,
                read_world_folder=dfhack.world.ReadWorldFolder},
        })
        local game_query_runtime = game_query_runtime_module.new({
            context=context, df=df, dfhack=dfhack})
        local run_query_runtime = run_query_runtime_module.new(
            assert(dfhack.dwarfspec,
                'DwarfSpec automation service is not running'))
        local capture_runtime = capture_runtime_module.new({
            run=context.run, diagnostics=diagnostics})
        local mount_query_runtime = mount_query_runtime_module.new({
            mount_context=context.mount_context,
            subject_sources=native_subject_sources,
            subject_source=ESubjectSource,
            requests=subject_requests_module,
            paths=subject_paths_module,
            target_resolver=interaction_target_resolver,
            diagnostics=diagnostics,
            run=context.run,
        })
        local subject_query_runtime = subject_query_runtime_module.new({
            get_focus_list=get_focus_list,
            resolve_raw=function(subject)
                return context.mount_context:resolve_subject(
                    subject, 'subject raw access')
            end,
        })
        local subject_surface = {}
        local registrar = builtin_registrar_module.new({runner=command_runner,
            ds=ds, subject=subject_surface})
        registrar:register_all({
            builtin_modules.wait_frames.new(wait_runtime),
            builtin_modules.wait_ticks.new(wait_runtime),
            builtin_modules.await.new(wait_runtime),
            builtin_modules.await_event.new(wait_runtime),
            builtin_modules.is_game_paused.new(game_query_runtime),
            builtin_modules.get_game_speed.new(game_query_runtime),
            builtin_modules.get_tick.new(game_query_runtime),
            builtin_modules.get_time.new(game_query_runtime),
            builtin_modules.get_save_directory_name.new(game_query_runtime),
            builtin_modules.has_focus.new(game_query_runtime),
            builtin_modules.current_run.new(run_query_runtime),
            builtin_modules.root.new(mount_query_runtime),
            builtin_modules.get.new(mount_query_runtime),
            builtin_modules.inspect.new(mount_query_runtime),
            builtin_modules.capture_view_tree.new(mount_query_runtime),
            builtin_modules.capture_screen.new(capture_runtime),
            builtin_modules.subject_get_focus_list.new(subject_query_runtime),
            builtin_modules.subject_raw.new(subject_query_runtime),
            builtin_modules.search.new(search_runtime),
            builtin_modules.click.new(click_runtime),
            builtin_modules.get_view_pos.new(map_view_runtime),
            builtin_modules.set_view_pos.new(map_view_runtime),
            builtin_modules.mount_save_game.new(save_game_runtime),
            builtin_modules.stage_overlay_registration.new(
                overlay_transaction),
            builtin_modules.register_cleanup.new(register_cleanup_options),
        })
        verified_subject_queries = registrar:subject_surface()
        context.mount_context:bind_subject_queries({
            getFocusList=verified_subject_queries.getFocusList,
            raw=verified_subject_queries.raw,
        })
    end

    if next(extensions.commands) ~= nil then
        assert(command_runner ~= nil,
            'project command execution requires the verified command runner')
        M.bind_project_commands(ds, extensions.commands, command_runner)
    end

    context.mount_context.subject_commands = {
        click=function(subject, button) return ds.click(subject, button) end,
        hover=function(subject, anchor) return ds.hover(subject, anchor) end,
        move_pointer=function(subject, anchor)
            return ds.move_pointer(subject, anchor)
        end,
        mouseWheel=function(subject, options)
            return ds.mouseWheel(options, subject)
        end,
        input=function(subject, keys) return ds.input(keys, subject) end,
        type=function(subject, text) return ds.type(text, subject) end,
        redraw=function(subject, options)
            return ds.redraw(subject, options)
        end,
        inspect=function(subject, command_options)
            return ds.inspect(subject, command_options)
        end,
        search=function(subject, query, command_options)
            return ds.search(query, subject, command_options)
        end,
        getFocusList=verified_subject_queries and
            verified_subject_queries.getFocusList,
        raw=verified_subject_queries and verified_subject_queries.raw,
    }

    return ds, reset
end

return M
