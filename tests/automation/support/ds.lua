-- Live-game interaction namespace exported into isolated Busted specs.

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
    '/tests/automation/support/diagnostics.lua')
local pointer_adapter_module = load_automation_module(package_root,
    'dwarfspec.automation.pointer_adapter',
    '/tests/automation/support/pointer_adapter.lua')
local overlay_registration = load_automation_module(package_root,
    'dwarfspec.automation.overlay_registration',
    '/tests/automation/support/overlay_registration.lua')
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
local render_tracker_module = load_automation_module(package_root,
    'dwarfspec.render_tracker', '/src/dwarfspec/render_tracker.lua')
local subject_module = load_automation_module(package_root,
    'dwarfspec.subject', '/src/dwarfspec/subject.lua')
local MouseInput = load_automation_module(package_root,
    'dwarfspec.mouse_inputs', '/src/dwarfspec/mouse_inputs.lua')
local EventType = load_automation_module(package_root,
    'dwarfspec.automation.event_types',
    '/src/dwarfspec/automation/event_types.lua')
local TestStatus = load_automation_module(package_root,
    'dwarfspec.automation.test_statuses',
    '/src/dwarfspec/automation/test_statuses.lua')
    extensions = extensions or {settings={}, commands={}}
    mount_dependencies = mount_dependencies or {}
    local wait_settings = extensions.settings.wait or {}
    local context = {
        package_root=package_root,
        project=project,
        scheduler=scheduler,
        scheduler_module=scheduler_module,
        cleanup_module=cleanup_module,
        cleanup_registry=cleanup_registry,
        diagnostics=diagnostics,
        pointer=pointer_adapter_module.new(cleanup_module, cleanup_registry),
        run=scheduler.run,
        current_viewscreen=mount_dependencies.current_viewscreen or
            function() return dfhack.gui.getCurViewscreen(true) end,
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
        })
    end
    context.mount_context = mount_context_module.new({
        run=context.run,
        boundary=boundary,
        cleanup_module=cleanup_module,
        cleanup_registry=cleanup_registry,
        adapter_factory=adapter_factory,
        failure_reporter=mount_dependencies.failure_reporter or
            report_mount_failure,
        render_tracker_factory=new_render_tracker,
        subject_module=mount_dependencies.subject_module or subject_module,
        command_observer=command_observer,
    })
    context.run.mount_cleanup_probe = function()
        local state = context.mount_context:cleanup_state()
        state.pointer_active = context.pointer.patched_get_mouse_pos ~= nil
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
        MouseInput=MouseInput,
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
    ---@return any, table|nil, table|nil
    local function resolve_interaction_target(value, operation)
        if value == nil then
            local mount = context.mount_context:require_current(operation)
            return mount.root, mount.host_screen, mount
        end
        if context.mount_context.subject_mounts[value] then
            local view = context.mount_context:resolve_subject(value,
                operation)
            return view, context.mount_context.current.host_screen,
                context.mount_context.current
        end
        error(('DwarfSpec %s requires a subject from the current mount; ' ..
            'use ds.get(control_path) or ds.root()'):format(operation), 2)
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

    ---Polls a read-only condition once per frame until it becomes ready.
    ---@param description string
    ---@param query function
    ---@param options table|nil
    ---@return any
    function ds.await(description, query, options)
        return scheduler_module.wait_until(
            scheduler, description, query, wait_options(options, true))
    end

    ---Mounts one supported component as the run's implicit current mount.
    ---@param component any
    ---@param options table|nil
    ---@return table
    function ds.mount(component, options)
        return context.mount_context:mount(component, options)
    end

    ---Returns a subject for the current component root.
    ---@return table
    function ds.root()
        return context.mount_context:root()
    end

    ---Unmounts and settles the current component.
    function ds.unmount()
        return context.mount_context:unmount()
    end

    ---Selects one strict control path from the implicit current mount.
    ---@param control_path string
    ---@return table
    function ds.get(control_path)
        local mount = context.mount_context:require_current('get')
        local previous = mount.command_subject
        mount.command_subject = {
            mount_id=mount.id,
            control_path=control_path,
        }
        local ok, view = pcall(context.mount_context.resolve_control_path,
            context.mount_context, control_path)
        if not ok then
            local reported = context.mount_context:report_failure(
                mount, 'get', view)
            mount.command_subject = previous
            error(reported, 2)
        end
        mount.command_subject = previous
        return context.mount_context:new_subject(view, control_path)
    end

    ---Returns a stable read-only diagnostic table for one live view.
    ---@param view table
    ---@return table
    function ds.inspect(view)
        view = resolve_interaction_target(view, 'inspect')
        return diagnostics.inspect_view(view)
    end

    ---Captures the current implicit mount tree under one evidence name.
    ---@param name string
    ---@return table
    function ds.capture_view_tree(name)
        local root = context.mount_context:require_current(
            'capture_view_tree').root
        assert(type(name) == 'string' and name:match('^[%w_.-]+$'),
            'capture name must be a relative identifier')
        context.run.captures = context.run.captures or {}
        local tree = diagnostics.capture_view_tree(root)
        context.run.captures[name] = tree
        return tree
    end

    ---Moves the virtual pointer to an anchor inside one live view body.
    ---@param view table
    ---@param anchor string|nil
    ---@return integer, integer
    function ds.move_pointer(view, anchor)
        view = resolve_interaction_target(view, 'move_pointer')
        local body = assert(view.frame_body, 'view has no live frame body')
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
        context.mount_context:mutate('move_pointer', function()
            pointer_adapter_module.set(context.pointer, x, y)
        end)
        return x, y
    end

    ---Moves the virtual pointer over a subject and waits for its render.
    ---@param view table|nil
    ---@param anchor string|nil
    ---@return integer, integer
    function ds.hover(view, anchor)
        return ds.move_pointer(view, anchor)
    end

    ---Sends supported native input and waits for the live screen to settle.
    ---@param keys string|table
    ---@param subject table|nil
    ---@return integer
    function ds.input(keys, subject)
        local screen
        _, screen = resolve_interaction_target(subject, 'input')
        return context.mount_context:mutate('input', function()
            assert(is_active(screen), 'input screen is not currently active')
            require('gui').simulateInput(M.resolve_native_screen(
                screen, context.current_viewscreen), keys)
        end)
    end

    local mouse_inputs = {
        [MouseInput.LEFT_CLICK]={key='_MOUSE_L'},
        [MouseInput.LEFT_DOWN]={
            key='_MOUSE_L_DOWN',
            down_field='mouse_lbut_down',
            lift_field='mouse_lbut_lift',
            is_down=true,
        },
        [MouseInput.LEFT_UP]={
            down_field='mouse_lbut_down',
            lift_field='mouse_lbut_lift',
            is_down=false,
        },
        [MouseInput.RIGHT_CLICK]={key='_MOUSE_R'},
        [MouseInput.RIGHT_DOWN]={
            key='_MOUSE_R_DOWN',
            down_field='mouse_rbut_down',
            lift_field='mouse_rbut_lift',
            is_down=true,
        },
        [MouseInput.RIGHT_UP]={
            down_field='mouse_rbut_down',
            lift_field='mouse_rbut_lift',
            is_down=false,
        },
        [MouseInput.MIDDLE_CLICK]={key='_MOUSE_M'},
        [MouseInput.MIDDLE_DOWN]={
            key='_MOUSE_M_DOWN',
            down_field='mouse_mbut_down',
            lift_field='mouse_mbut_lift',
            is_down=true,
        },
        [MouseInput.MIDDLE_UP]={
            down_field='mouse_mbut_down',
            lift_field='mouse_mbut_lift',
            is_down=false,
        },
        [MouseInput.SCROLL_UP]={key='CONTEXT_SCROLL_UP'},
        [MouseInput.SCROLL_DOWN]={key='CONTEXT_SCROLL_DOWN'},
    }

    ---Sends one mouse action at the current virtual pointer position.
    ---@param input DwarfSpecMouseInput
    ---@return integer
    function ds.mouseInput(input)
        local screen
        _, screen = resolve_interaction_target(nil, 'mouseInput')
        local descriptor = mouse_inputs[input]
        assert(descriptor, 'unsupported mouse input: ' .. tostring(input))
        local x, y = pointer_adapter_module.position(context.pointer)
        return context.mount_context:mutate('mouseInput', function()
            assert(is_active(screen),
                'mouse input screen is not currently active')
            local dispatch = function()
                pointer_adapter_module.with_interface_mouse(x, y, function()
                    require('gui').simulateInput(M.resolve_native_screen(
                        screen, context.current_viewscreen), descriptor.key)
                end)
            end
            if descriptor.is_down == nil then
                dispatch()
            else
                pointer_adapter_module.with_button_state(
                    context.pointer,
                    descriptor.down_field,
                    descriptor.lift_field,
                    descriptor.is_down,
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
        local screen
        view, screen = resolve_interaction_target(view, 'click')
        local key = ({left='_MOUSE_L', right='_MOUSE_R',
            middle='_MOUSE_M'})[button or 'left']
        assert(key, 'unsupported mouse button: ' .. tostring(button))
        local x, y = ds.move_pointer(requested_view)
        return context.mount_context:mutate('click', function()
            pointer_adapter_module.with_interface_mouse(x, y, function()
                require('gui').simulateInput(M.resolve_native_screen(
                    screen, context.current_viewscreen), key)
            end)
        end)
    end

    ---Types ASCII text through DFHack's supported string keycodes.
    ---@param text string
    ---@param subject table|nil
    ---@return integer
    function ds.type(text, subject)
        local screen
        _, screen = resolve_interaction_target(subject, 'type')
        return context.mount_context:mutate('type', function()
            assert(type(text) == 'string', 'text input must be a string')
            local gui = require('gui')
            for index = 1, #text do
                assert(text:byte(index) >= 1,
                    'text input cannot contain NUL bytes')
                gui.simulateInput(M.resolve_native_screen(
                    screen, context.current_viewscreen),
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
        inspect=function(subject) return ds.inspect(subject) end,
    }

    return ds, reset
end

return M
