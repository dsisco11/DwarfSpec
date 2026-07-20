-- Live-game interaction namespace exported into isolated Busted specs.

local M = {}

---Loads an installed DwarfSpec module or its source-tree equivalent.
---@param package_root string
---@param module_name string
---@param source_relative string
---@return table
local function load_automation_module(package_root, module_name,
        source_relative)
    local ok, module = pcall(require, module_name)
    if ok then return module end
    return assert(loadfile(package_root .. source_relative))()
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
---@return table
function M.new(package_root, project, scheduler_module, scheduler,
        cleanup_module, cleanup_registry, extensions)
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
    extensions = extensions or {settings={}, commands={}, diagnostics={}}
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
        run=scheduler.run,
    }
    local ds = {
        protocol_version=1,
    }

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
    function ds.wait_until(description, query, options)
        return scheduler_module.wait_until(
            scheduler, description, query, wait_options(options, true))
    end

    ---Restores all currently registered test-owned resources.
    function ds.reset()
        local ok, failures = cleanup_module.run(cleanup_registry, 'ds.reset')
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
                local entry = cleanup_module.push(cleanup_registry,
                    'dismiss fixture ' .. import_path, function()
                        if is_active(screen) then screen:dismiss() end
                        context.screen_entries[screen] = nil
                    end)
                context.screen_entries[screen] = entry
                associate_screen(context.screens, screen, screen)
                screen:show()
                if type(screen.on_automation_shown) == 'function' then
                    screen:on_automation_shown()
                end
                ds.wait_for_render(screen)
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
            cleanup_module.release(cleanup_registry,
                context.screen_entries[screen])
            context.screen_entries[screen] = nil
        end)
    end

    ---Finds one native propagated view id below a live fixture root.
    ---@param root table
    ---@param view_id string
    ---@return table
    function ds.get(root, view_id)
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
    function ds.move_pointer_to(view, anchor)
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
        ds.set_pointer(x, y)
        return x, y
    end

    ---Restores the original physical-pointer query function.
    function ds.clear_pointer()
        pointer_adapter_module.clear(context.pointer)
    end

    ---Waits for a fixture's instrumented real render generation to advance.
    ---@param view table
    ---@param previous_generation integer|nil
    ---@return integer
    function ds.wait_for_render(view, previous_generation)
        local screen = owner_screen(context.screens, view)
        assert(screen and type(screen.render_generation) == 'number',
            'view is not inside an instrumented automation fixture')
        previous_generation = previous_generation or screen.render_generation
        return scheduler_module.wait_until(scheduler, 'fixture render',
            function()
                return screen.render_generation > previous_generation and
                    screen.render_generation or false
            end)
    end

    ---Sends supported native keys and waits for the owning fixture to render.
    ---@param keys string|table
    ---@param screen table
    ---@return integer
    function ds.press(keys, screen)
        return run_action(context, 'press keys', screen, function()
            assert(screen and context.screen_entries[screen],
                'input screen is not owned by this automation run')
            local generation = screen.render_generation
            require('gui').simulateInput(native_screen(screen), keys)
            return ds.wait_for_render(screen, generation)
        end)
    end

    ---Sends input to one currently shown live screen through DFHack's native path.
    ---@param keys string|table
    ---@param screen table
    function ds.send_input(keys, screen)
        return run_action(context, 'send input', screen, function()
            assert(screen and is_active(screen),
                'input screen is not currently active')
            require('gui').simulateInput(native_screen(screen), keys)
            return ds.wait_frames(1, {description='wait after live input'})
        end)
    end

    ---Clicks a view with a supported native mouse button and waits for render.
    ---@param view table
    ---@param button string|nil
    ---@return integer
    function ds.click(view, button)
        return run_action(context, 'click view', view, function()
            local screen = assert(owner_screen(context.screens, view),
                'view is not inside an automation fixture')
            local key = ({left='_MOUSE_L', right='_MOUSE_R', middle='_MOUSE_M'})[
                button or 'left']
            assert(key, 'unsupported mouse button: ' .. tostring(button))
            local x, y = ds.move_pointer_to(view)
            local generation = screen.render_generation
            pointer_adapter_module.with_interface_mouse(x, y, function()
                require('gui').simulateInput(native_screen(screen), key)
            end)
            return ds.wait_for_render(screen, generation)
        end)
    end

    ---Types ASCII text through DFHack's supported string keycodes.
    ---@param text string
    ---@param screen table
    ---@return integer
    function ds.type(text, screen)
        return run_action(context, 'type text', screen, function()
            assert(type(text) == 'string', 'text input must be a string')
            assert(screen and context.screen_entries[screen],
                'input screen is not owned by this automation run')
            local generation = screen.render_generation
            local gui = require('gui')
            for index = 1, #text do
                assert(text:byte(index) >= 1,
                    'text input cannot contain NUL bytes')
                gui.simulateInput(native_screen(screen),
                    ('STRING_A%03d'):format(text:byte(index)))
            end
            return ds.wait_for_render(screen, generation)
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

    ---Invokes one named consumer diagnostic adapter in the isolated ds scope.
    ---@param name string
    ---@param ... any
    ---@return any
    function ds.diagnostic(name, ...)
        local adapter = extensions.diagnostics[name]
        assert(adapter, 'consumer diagnostic adapter was not found: ' ..
            tostring(name))
        return adapter.callback(ds, ...)
    end

    for name, command in pairs(extensions.commands) do
        local callback = command.callback
        ds[name] = function(...)
            return callback(ds, ...)
        end
    end

    return ds
end

return M
