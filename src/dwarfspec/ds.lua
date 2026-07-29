-- Production live-game namespace exported into isolated Busted specs.

local M = {}

---Loads an installed DwarfSpec module or its source-tree equivalent.
---@param package_root string
---@param module_name string
---@param source_relative string
---@return table
local function load_automation_module(package_root, module_name,
        source_relative)
    local source_path = package_root .. source_relative
    local source_file = io.open(source_path, 'rb')
    if source_file then
        source_file:close()
        return assert(loadfile(source_path))()
    end
    local ok, module = pcall(require, module_name)
    if ok then return module end
    error(module, 0)
end

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
---@return table
function M.new(package_root, project, scheduler_module, scheduler,
        cleanup_module, cleanup_registry, extensions, mount_dependencies)
    local example_cleanup_marker = cleanup_module.mark(cleanup_registry)
local diagnostics = load_automation_module(package_root,
    'dwarfspec.automation.diagnostics',
    '/src/dwarfspec/automation/diagnostics.lua')
local pointer_adapter_module = load_automation_module(package_root,
    'dwarfspec.automation.pointer_adapter',
    '/src/dwarfspec/automation/pointer_adapter.lua')
local overlay_registration = load_automation_module(package_root,
    'dwarfspec.automation.overlay_registration',
    '/src/dwarfspec/automation/overlay_registration.lua')
local component_module = load_automation_module(package_root,
    'dwarfspec.component', '/src/dwarfspec/component.lua')
local mount_context_module = load_automation_module(package_root,
    'dwarfspec.mount_context', '/src/dwarfspec/mount_context.lua')
local mount_adapters_module = load_automation_module(package_root,
    'dwarfspec.mount_adapters', '/src/dwarfspec/mount_adapters.lua')
local overlay_mount_module = load_automation_module(package_root,
    'dwarfspec.overlay_mount', '/src/dwarfspec/overlay_mount.lua')
local render_instrumentation = load_automation_module(package_root,
    'dwarfspec.render_instrumentation',
    '/src/dwarfspec/render_instrumentation.lua')
local native_render_observer_module = load_automation_module(package_root,
    'dwarfspec.native_render_observer',
    '/src/dwarfspec/native_render_observer.lua')
local render_tracker_module = load_automation_module(package_root,
    'dwarfspec.render_tracker', '/src/dwarfspec/render_tracker.lua')
local subject_module = load_automation_module(package_root,
    'dwarfspec.subject', '/src/dwarfspec/subject.lua')
local interaction_target_module = load_automation_module(package_root,
    'dwarfspec.interaction_target',
    '/src/dwarfspec/interaction_target.lua')
local lua_view_adapter_module = load_automation_module(package_root,
    'dwarfspec.lua_view_adapter',
    '/src/dwarfspec/lua_view_adapter.lua')
local native_attachment_module = load_automation_module(package_root,
    'dwarfspec.native_attachment',
    '/src/dwarfspec/native_attachment.lua')
local native_widget_adapter_module = load_automation_module(package_root,
    'dwarfspec.native_widget_adapter',
    '/src/dwarfspec/native_widget_adapter.lua')
local native_game_ui_path_module = load_automation_module(package_root,
    'dwarfspec.native_game_ui_path',
    '/src/dwarfspec/native_game_ui_path.lua')
local overlay_registry_adapter_module = load_automation_module(package_root,
    'dwarfspec.overlay_registry_adapter',
    '/src/dwarfspec/overlay_registry_adapter.lua')
local subject_paths_module = load_automation_module(package_root,
    'dwarfspec.subject_paths', '/src/dwarfspec/subject_paths.lua')
local subject_requests_module = load_automation_module(package_root,
    'dwarfspec.subject_requests', '/src/dwarfspec/subject_requests.lua')
local identity_labels = load_automation_module(package_root,
    'dwarfspec.identity_labels', '/src/dwarfspec/identity_labels.lua')
local EResolutionStage = load_automation_module(package_root,
    'dwarfspec.native_resolution_stages',
    '/src/dwarfspec/native_resolution_stages.lua')
local EMouseButton = load_automation_module(package_root,
    'dwarfspec.mouse_buttons', '/src/dwarfspec/mouse_buttons.lua')
local EInputState = load_automation_module(package_root,
    'dwarfspec.input_states', '/src/dwarfspec/input_states.lua')
local EPointerSpace = load_automation_module(package_root,
    'dwarfspec.pointer_spaces', '/src/dwarfspec/pointer_spaces.lua')
local EScreenOrigin = load_automation_module(package_root,
    'dwarfspec.screen_origins', '/src/dwarfspec/screen_origins.lua')
local ESubjectSource = load_automation_module(package_root,
    'dwarfspec.subject_sources', '/src/dwarfspec/subject_sources.lua')
local EventType = load_automation_module(package_root,
    'dwarfspec.automation.event_types',
    '/src/dwarfspec/automation/event_types.lua')
local TestStatus = load_automation_module(package_root,
    'dwarfspec.automation.test_statuses',
    '/src/dwarfspec/automation/test_statuses.lua')
    extensions = extensions or {settings={}, commands={}}
    mount_dependencies = mount_dependencies or {}
    local wait_settings = extensions.settings.wait or {}
    local pointer_screen = mount_dependencies.pointer_screen or dfhack.screen
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
        diagnostics=diagnostics,
        pointer=pointer_adapter_module.new(cleanup_module, cleanup_registry, {
            get_geometry=get_pointer_geometry,
            screen=pointer_screen,
            gps=pointer_gps,
            enabler=pointer_enabler,
        }),
        run=scheduler.run,
        current_viewscreen=mount_dependencies.current_viewscreen or
            function() return dfhack.gui.getCurViewscreen(true) end,
        get_window_size=mount_dependencies.get_window_size or
            function() return dfhack.screen.getWindowSize() end,
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
    }
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
        state.render_observer_active =
            context.mount_context.current ~= nil and
            context.mount_context.current.render_observer ~= nil
        return state
    end
    ---Stages one real overlay-registration source through run-owned cleanup.
    ---@param source_path string
    ---@param logical_name string
    ---@return table
    local function stage_overlay_registration_integration(
            source_path, logical_name)
        return overlay_registration.stage(project, source_path, logical_name,
            context.run.run_id, cleanup_module, cleanup_registry)
    end
    context.run.overlay_registration_integration =
        stage_overlay_registration_integration
    local ds = {
        protocol_version=1,
        EMouseButton=EMouseButton,
        EInputState=EInputState,
        EPointerSpace=EPointerSpace,
        EScreenOrigin=EScreenOrigin,
        ESubjectSource=ESubjectSource,
    }

    ---Returns the exact service-owned run that currently owns the executor.
    ---@return table
    function ds.current_run()
        local registry = assert(dfhack.dwarfspec,
            'DwarfSpec automation service is not running')
        local run_id = assert(registry.active_run_id,
            'DwarfSpec automation executor is idle')
        return assert(registry.runs[run_id],
            'DwarfSpec active run record is missing')
    end

    ---Resolves a subject or omitted target against the implicit mount.
    ---@param value any
    ---@param operation string
    ---@return any, dwarfspec.OwnedScreenInteractionTarget|dwarfspec.BorrowedNativeInteractionTarget|nil, table|nil, dwarfspec.SubjectAdapter|nil
    local function resolve_interaction_target(value, operation)
        if value == nil then
            local mount = context.mount_context:require_current(operation)
            local adapter = mount.subject_source.adapter
            return adapter:root(), mount.interaction_target, mount, adapter
        end
        if context.mount_context.subject_mounts[value] then
            local view = context.mount_context:resolve_subject(value,
                operation)
            local mount = context.mount_context.current
            return view, mount.interaction_target, mount,
                value._descriptor.adapter
        end
        error(('DwarfSpec %s requires a subject from the current mount; ' ..
            'use ds.get(control_path) or ds.root()'):format(operation), 2)
    end

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

    ---Copies caller wait options and applies project-wide defaults.
    ---@param options table|nil
    ---@param include_frame_budget boolean
    ---@return table
    local function wait_options(options, include_frame_budget)
        local result = {}
        for key, value in pairs(options or {}) do result[key] = value end
        if result.timeout_ms == nil then
            result.timeout_ms = wait_settings.timeout_ms
        end
        if include_frame_budget and result.frame_budget == nil then
            result.frame_budget = wait_settings.frame_budget
        end
        return result
    end

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

    ---Waits for actual DFHack raw-frame callbacks without blocking the game.
    ---@param count integer
    ---@param options table|nil
    ---@return integer
    function ds.wait_frames(count, options)
        return scheduler_module.wait_frames(scheduler, count,
            wait_options(options, false))
    end

    ---Waits for unpaused Dwarf Fortress simulation ticks without blocking.
    ---@param count integer
    ---@param options table|nil Supports `timeout_ms` and `description`.
    ---@return integer
    function ds.wait_ticks(count, options)
        return scheduler_module.wait_ticks(scheduler, count,
            wait_options(options, false))
    end

    ---Polls a read-only condition once per frame until it becomes ready.
    ---@param description string
    ---@param query function
    ---@param options table|nil
    ---@return any
    function ds.await(description, query, options)
        return scheduler_module.wait_until(
            scheduler, description, query, wait_options(options, true))
    end

    ---Returns whether the Dwarf Fortress simulation is currently paused.
    ---@return boolean
    function ds.isGamePaused()
        local global = df and df.global
        local pause_state = global and global.pause_state
        assert(type(pause_state) == 'boolean',
            'DwarfSpec isGamePaused requires a valid df.global.pause_state')
        return pause_state
    end

    ---Sets the game pause state for the current example.
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

    ---Returns whether a value is a finite Lua number.
    ---@param value any
    ---@return boolean
    local function is_finite_number(value)
        return type(value) == 'number' and value == value and
            value ~= math.huge and value ~= -math.huge
    end

    ---Returns whether two finite numbers match within float precision.
    ---@param actual number
    ---@param expected number
    ---@return boolean
    local function game_speed_ratio_matches(actual, expected)
        if not is_finite_number(actual) or
                not is_finite_number(expected) then
            return false
        end
        local scale = math.max(1, math.abs(expected))
        return math.abs(actual - expected) <= 1e-6 * scale
    end

    ---Reads and validates the native fields that define the game TPS target.
    ---@return table, number, number, number
    local function game_speed_state()
        local enabler = context.get_game_enabler()
        assert(enabler ~= nil,
            'DwarfSpec setGameSpeed requires df.global.enabler')
        local native_tps = enabler.fps
        assert(is_finite_number(native_tps) and native_tps >= 1 and
                native_tps % 1 == 0,
            'DwarfSpec setGameSpeed requires a valid positive integer ' ..
                'df.global.enabler.fps')
        local graphical_rate = enabler.gfps
        assert(is_finite_number(graphical_rate) and graphical_rate > 0,
            'DwarfSpec setGameSpeed requires a valid positive ' ..
                'df.global.enabler.gfps')
        local speed_ratio = enabler.fps_per_gfps
        assert(is_finite_number(speed_ratio),
            'DwarfSpec setGameSpeed requires a valid ' ..
                'df.global.enabler.fps_per_gfps')
        return enabler, native_tps, graphical_rate, speed_ratio
    end

    ---Sets the game ticks-per-second target for the current example.
    ---@param tps integer
    ---@return integer
    function ds.setGameSpeed(tps)
        assert(is_finite_number(tps) and tps >= 1 and tps % 1 == 0,
            'game speed must be a positive integer TPS target')
        local enabler, original_tps, graphical_rate, original_ratio =
            game_speed_state()
        if context.game_speed_cleanup_entry == nil then
            context.game_speed_cleanup_entry = cleanup_module.push(
                cleanup_registry, 'restore game speed', function()
                    local current = context.get_game_enabler()
                    assert(current ~= nil,
                        'DwarfSpec could not restore game speed: ' ..
                            'df.global.enabler is unavailable')
                    local restored = context.set_game_speed(
                        current, original_tps, original_ratio)
                    assert(restored ~= false,
                        'DFHack rejected the original game speed')
                    assert(current.fps == original_tps and
                        current.fps_per_gfps == original_ratio,
                        'DFHack did not restore the original game speed')
                    context.game_speed_cleanup_entry = nil
                end)
        end

        local expected_ratio = tps / graphical_rate
        local ok, accepted = pcall(
            context.set_game_speed, enabler, tps, expected_ratio)
        assert(ok, 'DwarfSpec could not set game speed: ' ..
            tostring(accepted))
        assert(accepted ~= false,
            'DFHack rejected the requested game speed')
        assert(enabler.fps == tps,
            'DFHack did not apply the requested game TPS target')
        assert(game_speed_ratio_matches(
            enabler.fps_per_gfps, expected_ratio),
            'DFHack did not apply the requested game speed ratio')
        return tps
    end

    ---Returns the current in-year simulation tick for the loaded DF world.
    ---@return integer
    function ds.getTick()
        local global = df and df.global
        local tick = global and global.cur_year_tick
        assert(type(tick) == 'number' and tick % 1 == 0 and tick >= 0,
            'DwarfSpec getTick requires a loaded world with a valid ' ..
                'df.global.cur_year_tick')
        return tick
    end

    ---Returns DFHack's current millisecond clock value.
    ---@return integer
    function ds.getTime()
        local get_tick_count = dfhack and dfhack.getTickCount
        assert(type(get_tick_count) == 'function',
            'DwarfSpec getTime requires dfhack.getTickCount')
        local time = get_tick_count()
        assert(type(time) == 'number' and time % 1 == 0 and time >= 0,
            'DFHack getTickCount did not return a valid millisecond clock')
        return time
    end

    ---Returns whether the current DFHack focus matches one focus path.
    ---@param path string
    ---@return boolean
    function ds.hasFocus(path)
        assert(type(path) == 'string' and path ~= '',
            'focus path must be a nonempty string')
        local gui = dfhack and dfhack.gui
        assert(type(gui) == 'table' and
                type(gui.matchFocusString) == 'function',
            'DwarfSpec hasFocus requires dfhack.gui.matchFocusString')
        local focused = gui.matchFocusString(path)
        assert(type(focused) == 'boolean',
            'DFHack matchFocusString did not return a boolean')
        return focused
    end

    local screen_origin_axes = {
        [EScreenOrigin.TOP_LEFT]={'start', 'start'},
        [EScreenOrigin.TOP]={'center', 'start'},
        [EScreenOrigin.TOP_RIGHT]={'finish', 'start'},
        [EScreenOrigin.LEFT]={'start', 'center'},
        [EScreenOrigin.CENTER]={'center', 'center'},
        [EScreenOrigin.RIGHT]={'finish', 'center'},
        [EScreenOrigin.BOTTOM_LEFT]={'start', 'finish'},
        [EScreenOrigin.BOTTOM]={'center', 'finish'},
        [EScreenOrigin.BOTTOM_RIGHT]={'finish', 'finish'},
    }

    ---Returns one axis offset for a viewport anchor.
    ---@param anchor string
    ---@param size integer
    ---@return integer
    local function screen_origin_axis_offset(anchor, size)
        if anchor == 'start' then return 0 end
        if anchor == 'center' then return math.floor(size / 2) end
        return size - 1
    end

    ---Returns the map-tile offset for one screen origin.
    ---@param origin DwarfSpecEScreenOrigin|nil
    ---@return integer, integer
    local function screen_origin_offset(origin)
        origin = origin or EScreenOrigin.CENTER
        local axes = screen_origin_axes[origin]
        assert(axes,
            'screen origin must be a ds.EScreenOrigin value')
        if origin == EScreenOrigin.TOP_LEFT then return 0, 0 end
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
        return screen_origin_axis_offset(axes[1], width),
            screen_origin_axis_offset(axes[2], height)
    end

    ---Returns the map tile aligned with one origin in the current view.
    ---@param origin DwarfSpecEScreenOrigin|nil
    ---@return dwarfspec.MapViewPosition
    function ds.getViewPos(origin)
        local offset_x, offset_y = screen_origin_offset(origin)
        local ok, x, y, z = pcall(context.get_map_view_position)
        assert(ok, 'DwarfSpec could not query the current map-view position: ' ..
            tostring(x))
        for axis, value in pairs({x=x, y=y}) do
            assert(type(value) == 'number' and value % 1 == 0,
                ('DFHack returned an invalid map-view %s coordinate: %s')
                    :format(axis, tostring(value)))
        end
        assert(type(z) == 'number' and z % 1 == 0 and z >= 0,
            ('DFHack returned an invalid map-view z coordinate: %s')
                :format(tostring(z)))
        return {x=x + offset_x, y=y + offset_y, z=z}
    end

    ---Aligns one map tile with a screen origin for the current example.
    ---@param position table
    ---@param origin DwarfSpecEScreenOrigin|nil
    ---@return table
    function ds.setViewPos(position, origin)
        assert(type(position) == 'table',
            'map-view position must be a table with x, y, and z coordinates')
        for _, axis in ipairs({'x', 'y', 'z'}) do
            local value = position[axis]
            assert(type(value) == 'number' and value % 1 == 0 and value >= 0,
                ('map-view %s coordinate must be a nonnegative integer')
                    :format(axis))
        end
        local offset_x, offset_y = screen_origin_offset(origin)
        if context.map_view_cleanup_entry == nil then
            local original = ds.getViewPos(EScreenOrigin.TOP_LEFT)
            context.map_view_cleanup_entry = cleanup_module.push(
                cleanup_registry, 'restore map-view position', function()
                    local restored = context.set_map_view_position(
                        original.x, original.y, original.z)
                    assert(restored ~= false,
                        'DFHack rejected the original map-view position')
                    context.map_view_cleanup_entry = nil
                end)
        end
        local ok, accepted = pcall(context.set_map_view_position,
            position.x - offset_x, position.y - offset_y, position.z)
        assert(ok, 'DwarfSpec could not set the map-view position: ' ..
            tostring(accepted))
        assert(accepted ~= false,
            'DFHack rejected the requested map-view position')
        return {x=position.x, y=position.y, z=position.z}
    end

    ---Mounts one owned component or complete screen.
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
    ---@param ... any
    ---@return table
    function ds.mountNativeScreen(...)
        assert(select('#', ...) == 0,
            'DwarfSpec ds.mountNativeScreen() does not accept arguments')
        return context.mount_context:mount_native_screen(function()
            return native_attachment:attach()
        end)
    end

    ---Returns a subject for the selected current-mount root.
    ---@param options dwarfspec.SubjectSourceOptions|nil
    ---@return table
    function ds.root(options)
        local mount = context.mount_context:require_current('root')
        if mount.subject_source.kind ~= ESubjectSource.NATIVE then
            assert(options == nil,
                'component mounts do not accept subject source options')
            return context.mount_context:root()
        end
        local request = subject_requests_module.root(options)
        local source = select_subject_source(mount, request)
        if source == mount.subject_source then
            return context.mount_context:root()
        end
        local root = source.adapter:root()
        return context.mount_context:new_subject(
            root, '<root>', {}, source)
    end

    ---Releases the current native attachment or mounted component.
    function ds.unmount()
        return context.mount_context:unmount()
    end

    ---Selects one strict source-specific path from the implicit mount.
    ---@param control_path string|dwarfspec.NativePathSegment[]
    ---@param options dwarfspec.SubjectSourceOptions|nil
    ---@return table
    function ds.get(control_path, options)
        local mount = context.mount_context:require_current('get')
        local path_segments
        local diagnostic_path = control_path
        local source = mount.subject_source
        local use_implicit_native_roots = false
        if mount.subject_source.kind == ESubjectSource.NATIVE then
            local request = subject_requests_module.get(
                control_path, options)
            source = select_subject_source(mount, request)
            path_segments = request.path_segments
            use_implicit_native_roots =
                request.source == ESubjectSource.NATIVE and
                request.native_root == nil
            if request.source == ESubjectSource.NATIVE then
                diagnostic_path =
                    subject_paths_module.format_native(path_segments)
            end
        else
            assert(options == nil,
                'component mounts do not accept subject source options')
        end
        local previous = mount.command_subject
        mount.command_subject = {
            mount_id=mount.id,
            control_path=diagnostic_path,
        }
        local selected_path_segments = path_segments
        local ok, selected = pcall(function()
            if use_implicit_native_roots then
                return resolve_implicit_native_path(
                    mount, path_segments, diagnostic_path)
            end
            if path_segments then
                return {
                    view=context.mount_context:resolve_path_segments(
                        path_segments, diagnostic_path, source),
                    source=source,
                    path_segments=path_segments,
                }
            end
            return {
                view=context.mount_context:resolve_control_path(control_path),
                source=source,
                path_segments=nil,
            }
        end)
        if not ok then
            local reported = context.mount_context:report_failure(
                mount, 'get', selected)
            mount.command_subject = previous
            error(reported, 2)
        end
        mount.command_subject = previous
        source = selected.source
        selected_path_segments = selected.path_segments
        return context.mount_context:new_subject(
            selected.view, diagnostic_path, selected_path_segments, source)
    end

    ---Returns a stable read-only diagnostic table for one live subject.
    ---@param view table|nil Defaults to the current source root.
    ---@return table
    function ds.inspect(view)
        local adapter
        view, _, _, adapter = resolve_interaction_target(view, 'inspect')
        return diagnostics.inspect_view(view, adapter)
    end

    ---Returns a copied focus-string list for one current mounted subject.
    ---@param subject table
    ---@return string[]
    local function get_focus_list(subject)
        local interaction_target
        _, interaction_target = resolve_interaction_target(subject,
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
        _, interaction_target = resolve_interaction_target(view, 'redraw')
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

    ---Captures the current implicit mount tree under one evidence name.
    ---@param name string
    ---@param options dwarfspec.SubjectSourceOptions|nil
    ---@return table
    function ds.capture_view_tree(name, options)
        local mount = context.mount_context:require_current(
            'capture_view_tree')
        local source = mount.subject_source
        if mount.subject_source.kind == ESubjectSource.NATIVE then
            local request = subject_requests_module.tree(options)
            source = select_subject_source(mount, request)
        else
            assert(options == nil,
                'component mounts do not accept subject source options')
        end
        local adapter = source.adapter
        local root = adapter:root()
        assert(type(name) == 'string' and name:match('^[%w_.-]+$'),
            'capture name must be a relative identifier')
        context.run.captures = context.run.captures or {}
        local tree = diagnostics.capture_view_tree(root, nil, adapter)
        context.run.captures[name] = tree
        return tree
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

    ---Moves the virtual pointer to coordinates or an anchor inside a subject.
    ---@overload fun(x: integer, y: integer, space: DwarfSpecEPointerSpace|nil): integer, integer
    ---@param view table|integer|nil
    ---@param anchor string|integer|nil
    ---@param space DwarfSpecEPointerSpace|nil
    ---@return integer, integer
    function ds.move_pointer(view, anchor, space)
        local explicit_space = space ~= nil
        if explicit_space and
                (type(view) == 'table' or view == nil) then
            error('pointer coordinate space is only valid with numeric ' ..
                'coordinates', 2)
        end
        if type(view) == 'number' or explicit_space then
            local target
            _, target = resolve_interaction_target(nil, 'move_pointer')
            local x = view
            local y = anchor
            space = space or EPointerSpace.GRID
            assert(space == EPointerSpace.GRID or
                    space == EPointerSpace.PIXELS,
                'unsupported pointer coordinate space: ' .. tostring(space))
            if space == EPointerSpace.GRID then
                assert(type(x) == 'number' and x % 1 == 0 and x >= 0,
                    'pointer x coordinate must be a nonnegative integer')
                assert(type(y) == 'number' and y % 1 == 0 and y >= 0,
                    'pointer y coordinate must be a nonnegative integer')
                local width, height =
                    current_window_size(target, 'move_pointer')
                assert(x < width,
                    ('pointer x coordinate %d is outside the current ' ..
                        'window width %d'):format(x, width))
                assert(y < height,
                    ('pointer y coordinate %d is outside the current ' ..
                        'window height %d'):format(y, height))
            end
            local geometry = pointer_adapter_module.geometry(context.pointer)
            local position = pointer_adapter_module.normalize_position(
                x, y, space, geometry)
            mutate_pointer('move_pointer', function()
                pointer_adapter_module.set(context.pointer, position)
            end)
            return x, y
        end
        local requested_subject = view
        local adapter
        local target
        local mount
        view, target, mount, adapter = resolve_interaction_target(
            view, 'move_pointer')
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
        anchor = anchor or 'center'
        local x = math.floor((body.x1 + body.x2) / 2)
        local y = math.floor((body.y1 + body.y2) / 2)
        if anchor == 'top_left' then
            x, y = body.x1, body.y1
        elseif anchor == 'top_right' then
            x, y = body.x2, body.y1
        elseif anchor == 'bottom_left' then
            x, y = body.x1, body.y2
        elseif anchor == 'bottom_right' then
            x, y = body.x2, body.y2
        else
            assert(anchor == 'center', 'unsupported pointer anchor: ' .. anchor)
        end
        mutate_pointer('move_pointer', function()
            local geometry = pointer_adapter_module.geometry(context.pointer)
            local position = pointer_adapter_module.normalize_position(
                x, y, EPointerSpace.GRID, geometry)
            pointer_adapter_module.set(context.pointer, position)
        end)
        return x, y
    end

    ---Moves the virtual pointer over a subject and waits for its render.
    ---@param view table|integer|nil
    ---@param anchor string|integer|nil
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
        _, interaction_target = resolve_interaction_target(subject, 'input')
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

    ---Sends one mouse action at the current virtual pointer position.
    ---@param button DwarfSpecEMouseButton
    ---@param action DwarfSpecEInputState|nil
    ---@return integer
    function ds.mouseInput(button, action)
        local interaction_target
        _, interaction_target = resolve_interaction_target(nil, 'mouseInput')
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

    ---Clicks a view with a supported native mouse button and waits for render.
    ---@param view table
    ---@param button string|nil
    ---@return integer
    function ds.click(view, button)
        local requested_view = view
        local interaction_target
        view, interaction_target = resolve_interaction_target(view, 'click')
        local key = ({left='_MOUSE_L', right='_MOUSE_R',
            middle='_MOUSE_M'})[button or 'left']
        assert(key, 'unsupported mouse button: ' .. tostring(button))
        ds.move_pointer(requested_view)
        return mutate_pointer('click', function()
            pointer_adapter_module.with_mouse_focus(
                context.pointer, function()
                    pointer_adapter_module.sync(context.pointer)
                    simulate_input(interaction_target, 'click', key)
                end)
        end)
    end

    ---Types ASCII text through DFHack's supported string keycodes.
    ---@param text string
    ---@param subject table|nil
    ---@return integer
    function ds.type(text, subject)
        local interaction_target
        _, interaction_target = resolve_interaction_target(subject, 'type')
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
    ---@param width integer
    ---@param height integer
    function ds.viewport(width, height)
        return context.mount_context:viewport(width, height)
    end

    ---Captures and retains a bounded plain screen-cell buffer.
    ---@param name string
    ---@param options table|nil
    ---@return table
    function ds.capture_screen(name, options)
        assert(type(name) == 'string' and name:match('^[%w_.-]+$'),
            'capture name must be a relative identifier')
        context.run.captures = context.run.captures or {}
        local capture = diagnostics.capture_screen(options)
        context.run.captures[name] = capture
        return capture
    end

    ---Stages a real overlay source for a registration integration test.
    ---@param source_path string
    ---@param logical_name string
    ---@return table
    function ds.stage_overlay_registration(source_path, logical_name)
        return stage_overlay_registration_integration(
            source_path, logical_name)
    end

    for name, command in pairs(extensions.commands) do
        local callback = command.callback
        ds[name] = function(...)
            local observation = command_observer.started(name, {
                mount_id=context.mount_context.current and
                    context.mount_context.current.id or 0,
                control_path='<custom>',
            })
            local arguments = table.pack(...)
            local results = table.pack(xpcall(function()
                return callback(ds,
                    table.unpack(arguments, 1, arguments.n))
            end, debug.traceback))
            command_observer.finished(observation, results[1],
                results[1] and nil or results[2])
            if not results[1] then error(results[2], 2) end
            return table.unpack(results, 2, results.n)
        end
    end

    context.mount_context.subject_commands = {
        click=function(subject, button) return ds.click(subject, button) end,
        hover=function(subject, anchor) return ds.hover(subject, anchor) end,
        move_pointer=function(subject, anchor)
            return ds.move_pointer(subject, anchor)
        end,
        input=function(subject, keys) return ds.input(keys, subject) end,
        type=function(subject, text) return ds.type(text, subject) end,
        redraw=function(subject, options)
            return ds.redraw(subject, options)
        end,
        inspect=function(subject) return ds.inspect(subject) end,
        getFocusList=get_focus_list,
    }

    return ds, reset
end

return M
