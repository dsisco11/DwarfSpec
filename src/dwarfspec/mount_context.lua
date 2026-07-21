-- Run-owned component mount lifecycle and weak subject ownership.

local M = {}

---Formats cleanup failures without discarding their registered names.
---@param failures table[]
---@return string
local function format_cleanup_failures(failures)
    local messages = {}
    for _, failure in ipairs(failures) do
        table.insert(messages, failure.name .. ': ' .. failure.message)
    end
    return table.concat(messages, '; ')
end

---Calls optional adapter teardown and always drops mount-owned references.
---@param context table
---@param mount table
local function cleanup_mount(context, mount)
    if mount.cleaned then return end
    local failures = {}
    if mount.adapter and type(mount.adapter.unmount) == 'function' then
        local ok, message = xpcall(function()
            mount.adapter:unmount(mount)
        end, debug.traceback)
        if not ok then table.insert(failures, tostring(message)) end
    end
    if mount.adapter and type(mount.adapter.settle) == 'function' then
        local ok, message = xpcall(function()
            mount.adapter:settle(mount)
        end, debug.traceback)
        if not ok then table.insert(failures, tostring(message)) end
    end

    mount.cleaned = true
    mount.active = false
    mount.root = nil
    mount.host_screen = nil
    mount.adapter = nil
    mount.cleanup_entry = nil
    mount.cleanup_entries = {}
    mount.refresh_views = nil
    for view in pairs(mount.owned_views) do
        if context.view_mounts[view] == mount.id then
            context.view_mounts[view] = nil
        end
    end
    mount.owned_views = setmetatable({}, {__mode='k'})
    mount.views_by_id = {}
    mount.duplicate_view_ids = {}
    mount.command_subject = nil
    for subject in pairs(mount.selected_subjects) do
        context.subject_mounts[subject] = nil
    end
    if context.current == mount then context.current = nil end
    if #failures > 0 then
        error('component adapter cleanup failed: ' ..
            table.concat(failures, '; '), 0)
    end
end

---Creates one component mount context owned by a single automation run.
---@param options table
---@return table
function M.new(options)
    assert(type(options) == 'table' and type(options.run) == 'table',
        'mount context requires an automation run')
    assert(type(options.boundary) == 'table' and
        type(options.boundary.classify) == 'function' and
        type(options.boundary.prepare) == 'function' and
        type(options.boundary.normalize_viewport) == 'function',
        'mount context requires a component boundary')
    assert(type(options.cleanup_module) == 'table' and
        type(options.cleanup_module.push) == 'function' and
        type(options.cleanup_module.mark) == 'function' and
        type(options.cleanup_module.run_from) == 'function',
        'mount context requires scoped cleanup support')
    assert(type(options.cleanup_registry) == 'table',
        'mount context requires a cleanup registry')
    assert(type(options.adapter_factory) == 'function',
        'mount context requires an adapter factory')
    assert(type(options.render_tracker_factory) == 'function',
        'mount context requires a render tracker factory')
    assert(type(options.subject_module) == 'table' and
        type(options.subject_module.new) == 'function',
        'mount context requires a subject factory')

    local context = {
        run=options.run,
        boundary=options.boundary,
        cleanup_module=options.cleanup_module,
        cleanup_registry=options.cleanup_registry,
        adapter_factory=options.adapter_factory,
        render_tracker_factory=options.render_tracker_factory,
        failure_reporter=options.failure_reporter,
        subject_module=options.subject_module,
        current=nil,
        next_mount_id=0,
        subject_mounts=setmetatable({}, {__mode='k'}),
        subject_commands={},
        view_mounts=setmetatable({}, {__mode='k'}),
        owned_screens=setmetatable({}, {__mode='k'}),
    }

    ---Returns plain lifecycle counts suitable for terminal cleanup evidence.
    ---@return table
    function context:cleanup_state()
        local active_screen_count = 0
        local tracked_screen_count = 0
        for screen in pairs(self.owned_screens) do
            tracked_screen_count = tracked_screen_count + 1
            local active = false
            if type(screen.isActive) == 'function' then
                local ok, value = pcall(screen.isActive, screen)
                active = ok and not not value
            elseif screen.active ~= nil then
                active = not not screen.active
            end
            if active then active_screen_count = active_screen_count + 1 end
        end
        local subject_count = 0
        for _ in pairs(self.subject_mounts) do
            subject_count = subject_count + 1
        end
        return {
            current_mount_id=self.current and self.current.id or nil,
            active_screen_count=active_screen_count,
            tracked_screen_count=tracked_screen_count,
            subject_count=subject_count,
        }
    end

    ---Refreshes weak ownership and ID indexes from the current native tree.
    ---@param mount table
    function context:refresh_views(mount)
        assert(type(mount) == 'table' and not mount.cleaned,
            'cannot refresh a cleaned component mount')
        for view in pairs(mount.owned_views) do
            if self.view_mounts[view] == mount.id then
                self.view_mounts[view] = nil
            end
        end
        mount.owned_views = setmetatable({}, {__mode='k'})
        mount.views_by_id = {}
        mount.duplicate_view_ids = {}
        local visited = setmetatable({}, {__mode='k'})

        ---Indexes one view and its ordered descendants exactly once.
        ---@param view table
        local function visit(view)
            if visited[view] then return end
            visited[view] = true
            self.view_mounts[view] = mount.id
            mount.owned_views[view] = true
            local view_id = view.view_id
            if type(view_id) == 'string' and view_id ~= '' then
                local existing = mount.views_by_id[view_id]
                if existing == nil then
                    mount.views_by_id[view_id] = view
                else
                    local duplicates = mount.duplicate_view_ids[view_id]
                    if duplicates == nil then
                        duplicates = {existing}
                        mount.duplicate_view_ids[view_id] = duplicates
                    end
                    table.insert(duplicates, view)
                end
            end
            for _, child in ipairs(view.subviews or {}) do visit(child) end
        end

        visit(mount.root)
    end

    ---Finds one indexed view ID in the current mounted component tree.
    ---@param view_id string
    ---@return table|nil
    function context:find_view(view_id)
        local mount = self:require_current('get')
        local duplicates = mount.duplicate_view_ids[view_id]
        if duplicates then
            error(('DwarfSpec get is ambiguous: view_id=%q mount=%s ' ..
                'matches %d views'):format(view_id, tostring(mount.id),
                    #duplicates), 2)
        end
        return mount.views_by_id[view_id]
    end

    ---Returns the current mount that owns a native view, if any.
    ---@param view table
    ---@return table|nil
    function context:mount_for_view(view)
        local mount = self.current
        if mount and self.view_mounts[view] == mount.id then return mount end
        return nil
    end

    ---Adds bounded mount diagnostics to an operational failure when available.
    ---@param mount table
    ---@param operation string
    ---@param failure any
    ---@return string
    function context:report_failure(mount, operation, failure)
        local original = tostring(failure)
        if type(self.failure_reporter) ~= 'function' then return original end
        local ok, reported = pcall(self.failure_reporter,
            mount, operation, original)
        if ok and reported ~= nil then return tostring(reported) end
        return original
    end

    ---Returns the current mount or raises a command-specific error.
    ---@param operation string
    ---@return table
    function context:require_current(operation)
        assert(type(operation) == 'string' and operation ~= '',
            'mount operation name must be a nonempty string')
        assert(self.current and self.current.active,
            ('DwarfSpec %s requires a mounted component; call ' ..
                'ds.mount(component, options) first'):format(operation))
        return self.current
    end

    ---Registers one cleanup action owned by the current mount.
    ---@param mount table
    ---@param name string
    ---@param action function
    ---@return table
    function context:push_cleanup(mount, name, action)
        assert(self.current == mount and not mount.cleaned,
            'cleanup can only be registered for the current mount')
        local entry = self.cleanup_module.push(self.cleanup_registry,
            name, action)
        table.insert(mount.cleanup_entries, entry)
        return entry
    end

    ---Creates and weakly tracks one subject in the current mount.
    ---@param view table
    ---@param view_id string|nil
    ---@return table
    function context:new_subject(view, view_id)
        local mount = self:require_current('subject creation')
        assert(self.view_mounts[view] == mount.id,
            'subject view is outside the current mount')
        local subject = self.subject_module.new(self, mount, view, view_id)
        self.subject_mounts[subject] = mount.id
        mount.selected_subjects[subject] = true
        return subject
    end

    ---Resolves a subject only while its original mount remains current.
    ---@param subject table
    ---@param operation string
    ---@return table
    function context:resolve_subject(subject, operation)
        local mount = self.current
        assert(mount and mount.active,
            ('DwarfSpec %s rejected stale subject view_id=%q from mount %s; ' ..
                'no component is currently mounted'):format(operation,
                    subject.view_id, tostring(subject.mount_id)))
        assert(self.subject_mounts[subject] == mount.id and
            subject.mount_id == mount.id,
            ('DwarfSpec %s rejected stale subject view_id=%q from mount %s; ' ..
                'current mount is %s'):format(operation, subject.view_id,
                    tostring(subject.mount_id), tostring(mount.id)))
        local view = subject._references and subject._references.view
        assert(view, ('DwarfSpec %s subject view_id=%q mount=%s native ' ..
            'object is no longer available'):format(operation,
                subject.view_id, tostring(subject.mount_id)))
        assert(self.view_mounts[view] == mount.id,
            ('DwarfSpec %s rejected subject view_id=%q mount=%s because ' ..
                'its view is outside the current mount'):format(operation,
                    subject.view_id, tostring(subject.mount_id)))
        return view
    end

    ---Executes one subject command immediately with retained selection context.
    ---@param subject table
    ---@param operation string
    ---@param ... any
    ---@return any
    function context:invoke_subject_command(subject, operation, ...)
        assert(type(operation) == 'string' and operation ~= '',
            'subject operation name must be a nonempty string')
        local mount = self.current
        local previous = mount and mount.command_subject or nil
        if mount then
            mount.command_subject = {
                mount_id=subject.mount_id,
                view_id=subject.view_id,
            }
        end
        local arguments = table.pack(...)
        local results = table.pack(xpcall(function()
            self:resolve_subject(subject, operation)
            local command = self.subject_commands[operation]
            assert(type(command) == 'function',
                'DwarfSpec subject command is unavailable: ' .. operation)
            return command(subject,
                table.unpack(arguments, 1, arguments.n))
        end, debug.traceback))
        local reported
        if not results[1] then
            reported = mount and
                self:report_failure(mount, operation, results[2]) or
                tostring(results[2])
        end
        if mount then mount.command_subject = previous end
        if not results[1] then
            error(('DwarfSpec subject failure: operation=%q view_id=%q ' ..
                'subject_mount=%s current_mount=%s cause=%s')
                :format(operation, subject.view_id,
                    tostring(subject.mount_id),
                    tostring(mount and mount.id or nil), reported), 2)
        end
        return table.unpack(results, 2, results.n)
    end

    ---Returns a subject for the current component root.
    ---@return table
    function context:root()
        local mount = self:require_current('root')
        return self:new_subject(mount.root, mount.root.view_id or '<root>')
    end

    ---Unmounts and settles the current component through scoped LIFO cleanup.
    function context:unmount()
        local mount = self:require_current('unmount')
        local ok, failures = self.cleanup_module.run_from(
            self.cleanup_registry, mount.cleanup_marker,
            'component unmount')
        if not ok then
            error('DwarfSpec unmount cleanup failed: ' ..
                format_cleanup_failures(failures), 2)
        end
    end

    ---Runs a mutating command and waits for its resulting completed render.
    ---@param operation string
    ---@param action function
    ---@return any
    function context:mutate(operation, action)
        assert(type(operation) == 'string' and operation ~= '',
            'mutation operation name must be a nonempty string')
        assert(type(action) == 'function',
            'mutation action must be a function')
        local mount = self:require_current(operation)
        local captured = mount.render_tracker:capture()
        local results = table.pack(xpcall(action, debug.traceback))
        if not results[1] then
            error(self:report_failure(mount, operation, results[2]), 2)
        end
        local wait_ok, wait_result = xpcall(function()
            return mount.render_tracker:wait_after(captured,
                operation .. ' render')
        end, debug.traceback)
        if not wait_ok then
            error(self:report_failure(mount, operation, wait_result), 2)
        end
        self:refresh_views(mount)
        return table.unpack(results, 2, results.n)
    end

    ---Changes the current mount viewport and waits for its completed render.
    ---@param width integer
    ---@param height integer
    ---@return any
    function context:viewport(width, height)
        local mount = self:require_current('viewport')
        local viewport = self.boundary:normalize_viewport({
            width=width,
            height=height,
        })
        assert(type(mount.adapter.viewport) == 'function',
            'component adapter must provide viewport() for ' ..
                mount.category)
        return self:mutate('viewport', function()
            mount.options.viewport.width = viewport.width
            mount.options.viewport.height = viewport.height
            return mount.adapter:viewport(mount, mount.options.viewport)
        end)
    end

    ---Activates one classified component when no mount is current.
    ---@param component any
    ---@param mount_options table|nil
    ---@return table
    function context:mount(component, mount_options)
        assert(not self.current,
            ('DwarfSpec mount rejected because mount %d is still current; ' ..
                'call ds.unmount() before mounting another component')
                :format(self.current and self.current.id or -1))

        local classification = self.boundary:classify(component)
        local adapter = self.adapter_factory(classification.category)
        assert(type(adapter) == 'table' and
            type(adapter.mount) == 'function',
            'component adapter must provide mount() for ' ..
                classification.category)
        self.next_mount_id = self.next_mount_id + 1
        local mount_attempt = {
            id=self.next_mount_id,
            run=self.run,
            category=classification.category,
            input_form=classification.input_form,
            component_class=classification.class,
            root=classification.input_form == 'instance' and component or nil,
            host_screen=nil,
            command_subject=nil,
        }
        local prepare_ok, prepared = xpcall(function()
            return self.boundary:prepare(component, mount_options)
        end, debug.traceback)
        if not prepare_ok then
            error(self:report_failure(mount_attempt, 'mount', prepared), 2)
        end
        local mount = {
            id=mount_attempt.id,
            run=self.run,
            category=prepared.category,
            input_form=prepared.input_form,
            component_class=prepared.class,
            root=prepared.component,
            host_screen=nil,
            render_tracker=self.render_tracker_factory(),
            adapter=adapter,
            active=false,
            cleaned=false,
            cleanup_marker=self.cleanup_module.mark(self.cleanup_registry),
            cleanup_entry=nil,
            cleanup_entries={},
            selected_subjects=setmetatable({}, {__mode='k'}),
            owned_views=setmetatable({}, {__mode='k'}),
            views_by_id={},
            duplicate_view_ids={},
            command_subject=nil,
            options=prepared.options,
        }
        mount.refresh_views = function() self:refresh_views(mount) end
        self.current = mount
        mount.cleanup_entry = self.cleanup_module.push(
            self.cleanup_registry,
            ('unmount component %d'):format(mount.id),
            function() cleanup_mount(self, mount) end)
        table.insert(mount.cleanup_entries, mount.cleanup_entry)

        local ok, result = xpcall(function()
            local captured = mount.render_tracker:capture()
            local adapter_result = adapter:mount(
                mount, prepared, function(name, action)
                return self:push_cleanup(mount, name, action)
            end)
            adapter_result = adapter_result or {}
            assert(type(adapter_result) == 'table',
                'component adapter mount() must return a table or nil')
            assert(type(adapter_result.root or prepared.component) == 'table',
                'component adapter root must be a native component object')
            mount.root = adapter_result.root or prepared.component
            mount.host_screen = adapter_result.host_screen
            if mount.host_screen then
                self.owned_screens[mount.host_screen] = true
            end
            mount.render_tracker:wait_after(captured, 'component mount render')
            return adapter_result
        end, debug.traceback)
        if not ok then
            local cleanup_ok, failures = self.cleanup_module.run_from(
                self.cleanup_registry, mount.cleanup_marker,
                'failed component mount')
            local message = 'DwarfSpec mount failed while activating ' ..
                prepared.category .. ' component: ' ..
                self:report_failure(mount, 'mount', result)
            if not cleanup_ok then
                message = message .. '; cleanup failed: ' ..
                    format_cleanup_failures(failures)
            end
            error(message, 2)
        end
        self:refresh_views(mount)
        mount.active = true
        local subject_ok, root_subject = xpcall(function()
            return self:root()
        end, debug.traceback)
        if not subject_ok then
            local cleanup_ok, failures = self.cleanup_module.run_from(
                self.cleanup_registry, mount.cleanup_marker,
                'failed root subject creation')
            local message = 'DwarfSpec mount failed while creating root ' ..
                'subject: ' .. tostring(root_subject)
            if not cleanup_ok then
                message = message .. '; cleanup failed: ' ..
                    format_cleanup_failures(failures)
            end
            error(message, 2)
        end
        return root_subject
    end

    return context
end

return M
