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

---Returns the test-owned fixture screen associated with one view.
---@param screens table
---@param view table
---@return table|nil
local function owner_screen(screens, view)
    if screens[view] then return screens[view] end
    local current = view
    while current do
        if screens[current] then return screens[current] end
        current = current.parent_view
    end
    return nil
end

---Associates a fixture screen with its ordered native view descendants.
---@param screens table
---@param screen table
---@param view table
local function associate_screen(screens, screen, view)
    screens[view] = screen
    for _, child in ipairs(view.subviews or {}) do
        associate_screen(screens, screen, child)
    end
end

---Returns whether a live screen is still active.
---@param screen table
---@return boolean
local function is_active(screen)
    if type(screen.isActive) ~= 'function' then return false end
    local ok, active = pcall(screen.isActive, screen)
    return ok and not not active
end

---Returns the native DFHack viewscreen owned by a shown GUI screen.
---@param screen table
---@return userdata
local function native_screen(screen)
    assert(screen._native, 'input screen is not shown')
    return screen._native
end

---Runs one action and retains fixture diagnostics if it fails operationally.
---@param context table
---@param operation string
---@param view table|nil
---@param action function
---@return any
local function run_action(context, operation, view, action)
    local ok, first, second, third = xpcall(action, debug.traceback)
    if ok then return first, second, third end
    local screen = view and owner_screen(context.screens, view) or nil
    local tree = nil
    if screen then
        local tree_ok, tree_value = pcall(
            context.diagnostics.capture_view_tree, screen)
        if tree_ok then tree = tree_value end
    end
    local capture_ok, capture_value = pcall(context.diagnostics.capture_screen,
        {max_width=16, max_height=8})
    local capture = capture_ok and capture_value or {width=0, height=0}
    context.run.last_interaction_diagnostics = {
        operation=operation,
        tree=tree,
        screen=capture,
        scheduler=context.scheduler.run.scheduler_state,
    }
    local tree_summary = tree and context.diagnostics.summarize_tree(tree) or
        '<none>'
    error(('automation interaction failed: operation=%q cause=%s ' ..
        'fixture_tree=%s screen_capture=%dx%d')
        :format(operation, tostring(first), tree_summary,
            capture.width, capture.height), 0)
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
local fixture_loader = load_automation_module(package_root,
    'dwarfspec.automation.fixture_loader',
    '/tests/automation/support/fixture_loader.lua')
local diagnostics = load_automation_module(package_root,
    'dwarfspec.automation.diagnostics',
    '/tests/automation/support/diagnostics.lua')
local pointer_adapter_module = load_automation_module(package_root,
    'dwarfspec.automation.pointer_adapter',
    '/tests/automation/support/pointer_adapter.lua')
local overlay_fixture = load_automation_module(package_root,
    'dwarfspec.automation.overlay_fixture',
    '/tests/automation/support/overlay_fixture.lua')
local component_module = load_automation_module(package_root,
    'dwarfspec.component', '/src/dwarfspec/component.lua')
local mount_context_module = load_automation_module(package_root,
    'dwarfspec.mount_context', '/src/dwarfspec/mount_context.lua')
local mount_adapters_module = load_automation_module(package_root,
    'dwarfspec.mount_adapters', '/src/dwarfspec/mount_adapters.lua')
local render_instrumentation = load_automation_module(package_root,
    'dwarfspec.render_instrumentation',
    '/src/dwarfspec/render_instrumentation.lua')
local render_tracker_module = load_automation_module(package_root,
    'dwarfspec.render_tracker', '/src/dwarfspec/render_tracker.lua')
local subject_module = load_automation_module(package_root,
    'dwarfspec.subject', '/src/dwarfspec/subject.lua')
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
        screens=setmetatable({}, {__mode='k'}),
        screen_entries=setmetatable({}, {__mode='k'}),
        screen_trackers=setmetatable({}, {__mode='k'}),
        run=scheduler.run,
    }
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
    })
    local ds = {
        protocol_version=1,
    }

    ---Requires a current mount when an interaction target is omitted.
    ---@param value any
    ---@param operation string
    local function require_interaction_target(value, operation)
        if value ~= nil then return end
        context.mount_context:require_current(operation)
        error(('DwarfSpec %s requires a subject or native legacy target')
            :format(operation), 2)
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
        local mount = context.mount_context:mount_for_view(value)
        if mount then return value, mount.host_screen, mount end
        return value, owner_screen(context.screens, value), nil
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

    ---Waits for DwarfSpec's private fixture render generation to advance.
    ---@param view table
    ---@param previous_generation integer|nil
    ---@return integer
    local function wait_for_render(view, previous_generation)
        local screen = owner_screen(context.screens, view)
        local tracker = screen and context.screen_trackers[screen]
        assert(tracker, 'view is not inside a DwarfSpec-owned fixture')
        previous_generation = previous_generation or tracker:capture()
        return tracker:wait_after(previous_generation, 'fixture render')
    end

    ---Restores all currently registered test-owned resources.
    local function reset()
        local ok, failures = cleanup_module.run(cleanup_registry,
            'automation lifecycle')
        if not ok then
            local messages = {}
            for _, failure in ipairs(failures) do
                table.insert(messages, failure.name .. ': ' .. failure.message)
            end
            error('automation cleanup failed: ' .. table.concat(messages, '; '),
                2)
        end
        scheduler_module.wait_frames(scheduler, 1, {
            description='wait for automation cleanup',
        })
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

    ---Shows an explicitly imported fixture and waits for its first real render.
    ---@param import_path string
    ---@param options table|nil
    ---@return table
    function ds.show_fixture(import_path, options)
        return run_action(context, 'show fixture ' .. tostring(import_path), nil,
            function()
                local fixture = fixture_loader.load(project, import_path)
                local pause_state = df.global.pause_state
                local screen = fixture.new(options)
                assert(type(screen.show) == 'function',
                    'automation fixture did not create a screen')
                cleanup_module.push(cleanup_registry,
                    'restore fixture pause state', function()
                        df.global.pause_state = pause_state
                    end)
                local tracker = new_render_tracker()
                local restore = render_instrumentation.install(screen, tracker,
                    function(failure)
                        return report_mount_failure({
                            id='legacy-fixture',
                            category='screen',
                            root=screen,
                            host_screen=screen,
                        }, 'render', failure)
                    end)
                local restore_entry = cleanup_module.push(cleanup_registry,
                    'restore fixture render interception ' .. import_path,
                    restore)
                local dismiss_entry = cleanup_module.push(cleanup_registry,
                    'dismiss fixture ' .. import_path, function()
                        if is_active(screen) then screen:dismiss() end
                        context.screen_entries[screen] = nil
                        context.screen_trackers[screen] = nil
                    end)
                context.screen_entries[screen] = {
                    dismiss=dismiss_entry,
                    restore=restore_entry,
                    restore_action=restore,
                }
                context.screen_trackers[screen] = tracker
                associate_screen(context.screens, screen, screen)
                local captured = tracker:capture()
                screen:show()
                if type(screen.on_automation_shown) == 'function' then
                    screen:on_automation_shown()
                end
                wait_for_render(screen, captured)
                return screen
            end)
    end

    ---Dismisses one test-owned fixture screen and waits until it is inactive.
    ---@param screen table
    function ds.dismiss(screen)
        return run_action(context, 'dismiss fixture', screen, function()
            assert(context.screen_entries[screen],
                'screen is not owned by this automation run')
            if is_active(screen) then screen:dismiss() end
            scheduler_module.wait_until(scheduler, 'fixture dismissal',
                function() return not is_active(screen) end)
            local entries = context.screen_entries[screen]
            cleanup_module.release(cleanup_registry, entries.dismiss)
            entries.restore_action()
            cleanup_module.release(cleanup_registry, entries.restore)
            context.screen_entries[screen] = nil
            context.screen_trackers[screen] = nil
        end)
    end

    ---Finds one native propagated view id below a live fixture root.
    ---@param root table
    ---@param view_id string
    ---@return table
    function ds.get(root, view_id)
        if view_id == nil then
            view_id = root
            local mount = context.mount_context:require_current('get')
            assert(type(view_id) == 'string' and view_id ~= '',
                'view id must be a nonempty string')
            local view = context.mount_context:find_view(view_id)
            assert(view and view.view_id == view_id,
                'current mount view id was not found: ' .. view_id)
            return context.mount_context:new_subject(view)
        end
        assert(type(view_id) == 'string' and view_id ~= '',
            'view id must be a nonempty string')
        local view = root.subviews and root.subviews[view_id]
        assert(view and view.view_id == view_id,
            'live view id was not found: ' .. view_id)
        return view
    end

    ---Returns a stable read-only diagnostic table for one live view.
    ---@param view table
    ---@return table
    function ds.inspect(view)
        view = resolve_interaction_target(view, 'inspect')
        return diagnostics.inspect_view(view)
    end

    ---Captures and retains one live fixture tree under a caller-selected name.
    ---@param root table
    ---@param name string
    ---@return table
    function ds.capture_view_tree(root, name)
        assert(type(name) == 'string' and name:match('^[%w_.-]+$'),
            'capture name must be a relative identifier')
        context.run.captures = context.run.captures or {}
        local tree = diagnostics.capture_view_tree(root)
        context.run.captures[name] = tree
        return tree
    end

    ---Installs a virtual interface pointer position for this automation run.
    ---@param x integer
    ---@param y integer
    function ds.set_pointer(x, y)
        pointer_adapter_module.set(context.pointer, x, y)
    end

    ---Moves the virtual pointer to an anchor inside one live view body.
    ---@param view table
    ---@param anchor string|nil
    ---@return integer, integer
    function ds.move_pointer(view, anchor)
        local mount
        view, _, mount = resolve_interaction_target(view, 'move_pointer')
        local body = assert(view.frame_body, 'view has no live frame body')
        local screen = owner_screen(context.screens, view)
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
        if mount then
            context.mount_context:mutate('move_pointer', function()
                pointer_adapter_module.set(context.pointer, x, y)
            end)
        elseif screen then
            local tracker = context.screen_trackers[screen]
            local captured = tracker:capture()
            pointer_adapter_module.set(context.pointer, x, y)
            wait_for_render(screen, captured)
        else
            pointer_adapter_module.set(context.pointer, x, y)
            ds.wait_frames(1, {description='wait after pointer movement'})
        end
        return x, y
    end

    ---Moves the virtual pointer over a subject and waits for its render.
    ---@param view table|nil
    ---@param anchor string|nil
    ---@return integer, integer
    function ds.hover(view, anchor)
        return ds.move_pointer(view, anchor)
    end

    ---Restores the original physical-pointer query function.
    function ds.clear_pointer()
        pointer_adapter_module.clear(context.pointer)
    end

    ---Sends supported native input and waits for the live screen to settle.
    ---@param keys string|table
    ---@param screen table
    ---@return integer
    function ds.input(keys, screen)
        local mount
        _, screen, mount = resolve_interaction_target(screen, 'input')
        if mount then
            return context.mount_context:mutate('input', function()
                assert(is_active(screen),
                    'input screen is not currently active')
                require('gui').simulateInput(native_screen(screen), keys)
            end)
        end
        require_interaction_target(screen, 'input')
        return run_action(context, 'input', screen, function()
            assert(screen and is_active(screen),
                'input screen is not currently active')
            local tracker = context.screen_trackers[screen]
            local generation = tracker and tracker:capture() or nil
            require('gui').simulateInput(native_screen(screen), keys)
            if tracker then return wait_for_render(screen, generation) end
            return ds.wait_frames(1, {description='wait after live input'})
        end)
    end

    ---Clicks a view with a supported native mouse button and waits for render.
    ---@param view table
    ---@param button string|nil
    ---@return integer
    function ds.click(view, button)
        local requested_view = view
        local screen
        local mount
        view, screen, mount = resolve_interaction_target(view, 'click')
        if mount then
            local key = ({left='_MOUSE_L', right='_MOUSE_R',
                middle='_MOUSE_M'})[button or 'left']
            assert(key, 'unsupported mouse button: ' .. tostring(button))
            local x, y = ds.move_pointer(requested_view)
            return context.mount_context:mutate('click', function()
                pointer_adapter_module.with_interface_mouse(x, y, function()
                    require('gui').simulateInput(native_screen(screen), key)
                end)
            end)
        end
        require_interaction_target(view, 'click')
        return run_action(context, 'click view', view, function()
            screen = assert(screen or owner_screen(context.screens, view),
                'view is not inside an automation fixture')
            local key = ({left='_MOUSE_L', right='_MOUSE_R', middle='_MOUSE_M'})[
                button or 'left']
            assert(key, 'unsupported mouse button: ' .. tostring(button))
            local x, y = ds.move_pointer(view)
            local tracker = assert(context.screen_trackers[screen],
                'fixture has no DwarfSpec render tracker')
            local generation = tracker:capture()
            pointer_adapter_module.with_interface_mouse(x, y, function()
                require('gui').simulateInput(native_screen(screen), key)
            end)
            return wait_for_render(screen, generation)
        end)
    end

    ---Types ASCII text through DFHack's supported string keycodes.
    ---@param text string
    ---@param screen table
    ---@return integer
    function ds.type(text, screen)
        local mount
        _, screen, mount = resolve_interaction_target(screen, 'type')
        if mount then
            return context.mount_context:mutate('type', function()
                assert(type(text) == 'string',
                    'text input must be a string')
                local gui = require('gui')
                for index = 1, #text do
                    assert(text:byte(index) >= 1,
                        'text input cannot contain NUL bytes')
                    gui.simulateInput(native_screen(screen),
                        ('STRING_A%03d'):format(text:byte(index)))
                end
            end)
        end
        require_interaction_target(screen, 'type')
        return run_action(context, 'type text', screen, function()
            assert(type(text) == 'string', 'text input must be a string')
            assert(screen and context.screen_entries[screen],
                'input screen is not owned by this automation run')
            local tracker = assert(context.screen_trackers[screen],
                'fixture has no DwarfSpec render tracker')
            local generation = tracker:capture()
            local gui = require('gui')
            for index = 1, #text do
                assert(text:byte(index) >= 1,
                    'text input cannot contain NUL bytes')
                gui.simulateInput(native_screen(screen),
                    ('STRING_A%03d'):format(text:byte(index)))
            end
            return wait_for_render(screen, generation)
        end)
    end

    ---Applies a layout resize to the current mounted screen and waits.
    ---@param width integer
    ---@param height integer
    function ds.resize(width, height)
        local mount = context.mount_context:require_current('resize')
        assert(type(width) == 'number' and width >= 1 and
            type(height) == 'number' and height >= 1,
            'resize dimensions must be positive numbers')
        return context.mount_context:mutate('resize', function()
            mount.host_screen:onResize(width, height)
        end)
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

    ---Stages an explicitly imported overlay fixture for this run.
    ---@param import_path string
    ---@return table
    function ds.stage_overlay_fixture(import_path)
        return overlay_fixture.stage(project, import_path, context.run.run_id,
            cleanup_module, cleanup_registry)
    end

    for name, command in pairs(extensions.commands) do
        local callback = command.callback
        ds[name] = function(...)
            return callback(ds, ...)
        end
    end

    return ds, reset
end

return M
