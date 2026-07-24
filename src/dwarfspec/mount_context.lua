-- Run-owned component mount lifecycle and weak subject ownership.

local subject_paths = require('dwarfspec.subject_paths')

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

    ---Runs one mount cleanup callback and retains its traceback on failure.
    ---@param callback function
    local function attempt(callback)
        local ok, message = xpcall(callback, debug.traceback)
        if not ok then table.insert(failures, tostring(message)) end
    end

    if mount.adapter and type(mount.adapter.unmount) == 'function' then
        attempt(function()
            mount.adapter:unmount(mount)
        end)
    end
    if mount.adapter and type(mount.adapter.settle) == 'function' then
        attempt(function()
            mount.adapter:settle(mount)
        end)
    end
    for subject in pairs(mount.selected_subjects) do
        context.subject_mounts[subject] = nil
        attempt(function()
            context.subject_module.release(subject)
        end)
    end
    if mount.interaction_target and
            type(mount.interaction_target.cleanup) == 'function' then
        attempt(function()
            mount.interaction_target:cleanup()
        end)
    end
    local subject_adapter = mount.subject_source and
        mount.subject_source.adapter or nil
    if subject_adapter and type(subject_adapter.cleanup) == 'function' then
        attempt(function()
            subject_adapter:cleanup()
        end)
    end

    mount.cleaned = true
    mount.alive = false
    mount.root = nil
    mount.host_screen = nil
    mount.interaction_target = nil
    mount.subject_source = nil
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
    mount.command_subject = nil
    mount.selected_subjects = setmetatable({}, {__mode='k'})
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
        type(options.subject_module.new) == 'function' and
        type(options.subject_module.release) == 'function',
        'mount context requires a subject factory')
    if options.command_observer ~= nil then
        assert(type(options.command_observer) == 'table' and
            type(options.command_observer.started) == 'function' and
            type(options.command_observer.finished) == 'function',
            'mount context command observer is incomplete')
    end

    local context = {
        run=options.run,
        boundary=options.boundary,
        cleanup_module=options.cleanup_module,
        cleanup_registry=options.cleanup_registry,
        adapter_factory=options.adapter_factory,
        render_tracker_factory=options.render_tracker_factory,
        failure_reporter=options.failure_reporter,
        command_observer=options.command_observer,
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

    ---Formats one parent identity for control-path validation errors.
    ---@param control_path string|nil
    ---@return string
    local function parent_identity(control_path)
        if control_path == '' then return '<root>' end
        return control_path or '<anonymous>'
    end

    ---Returns the validated default subject adapter for one mount.
    ---@param mount table
    ---@return dwarfspec.SubjectAdapter
    local function subject_adapter(mount)
        local source = mount and mount.subject_source
        local adapter = source and source.adapter
        assert(type(adapter) == 'table' and
            type(adapter.root) == 'function' and
            type(adapter.resolve) == 'function' and
            type(adapter.identity) == 'function' and
            type(adapter.contains) == 'function' and
            type(adapter.children) == 'function' and
            type(adapter.name) == 'function' and
            type(adapter.native_type) == 'function' and
            type(adapter.bounds) == 'function' and
            type(adapter.visible) == 'function' and
            type(adapter.active) == 'function' and
            type(adapter.focused) == 'function' and
            type(adapter.text) == 'function' and
            type(adapter.tooltip) == 'function' and
            type(adapter.optional_fields) == 'function' and
            type(adapter.inspect) == 'function',
            'component mount subject adapter is incomplete')
        return adapter
    end

    ---Refreshes weak ownership and validates direct child control identities.
    ---@param mount table
    function context:refresh_views(mount)
        assert(type(mount) == 'table' and not mount.cleaned,
            'cannot refresh a cleaned component mount')
        local adapter = subject_adapter(mount)
        local owned_views = setmetatable({}, {__mode='k'})
        local visited = setmetatable({}, {__mode='k'})

        ---Records one view and validates each of its direct child IDs.
        ---@param view table
        ---@param control_path string|nil
        local function visit(view, control_path)
            if visited[view] then return end
            visited[view] = true
            owned_views[view] = true
            local child_ids = {}
            for _, child in ipairs(adapter:children(view)) do
                local child_id = adapter:name(child)
                local child_path = nil
                if type(child_id) == 'string' and child_id ~= '' then
                    assert(not child_id:find('/', 1, true),
                        ('DwarfSpec invalid component tree: parent ' ..
                        'control_path=%q has child view_id=%q containing "/"')
                            :format(parent_identity(control_path), child_id))
                    assert(child_id ~= '.' and child_id ~= '..',
                        ('DwarfSpec invalid component tree: parent ' ..
                        'control_path=%q has reserved child view_id=%q')
                            :format(parent_identity(control_path), child_id))
                    assert(not child_ids[child_id],
                        ('DwarfSpec invalid component tree: parent ' ..
                        'control_path=%q has multiple direct children with ' ..
                        'view_id=%q'):format(parent_identity(control_path),
                            child_id))
                    child_ids[child_id] = true
                    if control_path ~= nil then
                        child_path = control_path == '' and child_id or
                            control_path .. '/' .. child_id
                    end
                end
                visit(child, child_path)
            end
        end

        local root = adapter:root()
        assert(root == mount.root,
            'component subject source root changed during mount')
        visit(root, '')
        for view in pairs(mount.owned_views) do
            if self.view_mounts[view] == mount.id then
                self.view_mounts[view] = nil
            end
        end
        for view in pairs(owned_views) do self.view_mounts[view] = mount.id end
        mount.owned_views = owned_views
    end

    ---Formats the available direct child control IDs for one resolution error.
    ---@param view table
    ---@return string
    local function available_child_ids(view)
        local mount = context:require_current('get')
        local adapter = subject_adapter(mount)
        local ids = {}
        for _, child in ipairs(adapter:children(view)) do
            local child_id = adapter:name(child)
            if type(child_id) == 'string' and child_id ~= '' then
                table.insert(ids, child_id)
            end
        end
        table.sort(ids)
        local limit = 12
        local visible = {}
        for index, child_id in ipairs(ids) do
            if index > limit then break end
            table.insert(visible, child_id)
        end
        if #ids > limit then
            table.insert(visible, ('... (+%d more)'):format(#ids - limit))
        end
        return #visible > 0 and table.concat(visible, ', ') or '<none>'
    end

    ---Parses one strict component-relative control path.
    ---@param control_path string
    ---@return string[]
    local function parse_control_path(control_path)
        return subject_paths.component(control_path)
    end

    ---Resolves one strict path by walking direct mounted-component children.
    ---@param control_path string
    ---@return table
    function context:resolve_control_path(control_path)
        local mount = self:require_current('get')
        local segments = parse_control_path(control_path)
        local adapter = subject_adapter(mount)
        local view, failure = adapter:resolve(segments)
        if view then return view end
        local resolved = {}
        for index = 1, failure.index - 1 do
            table.insert(resolved, segments[index])
        end
        local resolved_path = table.concat(resolved, '/')
        assert(false,
            ('DwarfSpec get failed: control_path=%q mount=%s missing ' ..
            'segment=%q after=%q; available children=%s')
                :format(control_path, tostring(mount.id), failure.segment,
                    parent_identity(resolved_path),
                    available_child_ids(failure.parent)))
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
        assert(self.current and self.current.alive,
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
    ---@param control_path string|nil
    ---@return table
    function context:new_subject(view, control_path)
        local mount = self:require_current('subject creation')
        local source = mount.subject_source
        local adapter = subject_adapter(mount)
        assert(adapter:contains(view) and self.view_mounts[view] == mount.id,
            'subject view is outside the current mount')
        local diagnostic_path = control_path or '<root>'
        local path_segments = diagnostic_path == '<root>' and {} or
            parse_control_path(diagnostic_path)
        local subject = self.subject_module.new(self, mount, {
            mount_id=mount.id,
            source=source,
            path_segments=path_segments,
            adapter=adapter,
            captured_identity=adapter:identity(view),
            control_path_for_diagnostics=diagnostic_path,
        })
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
        assert(mount and mount.alive,
            ('DwarfSpec %s rejected stale subject control_path=%q from mount %s; ' ..
                'no component is currently mounted'):format(operation,
                    subject.control_path, tostring(subject.mount_id)))
        assert(self.subject_mounts[subject] == mount.id and
            subject.mount_id == mount.id,
            ('DwarfSpec %s rejected stale subject control_path=%q from mount %s; ' ..
                'current mount is %s'):format(operation, subject.control_path,
                    tostring(subject.mount_id), tostring(mount.id)))
        local descriptor = subject._descriptor
        assert(descriptor and descriptor.source == mount.subject_source and
            descriptor.adapter == subject_adapter(mount),
            ('DwarfSpec %s subject control_path=%q mount=%s descriptor ' ..
            'is no longer available'):format(operation,
                subject.control_path, tostring(subject.mount_id)))
        local view = descriptor.adapter:resolve(descriptor.path_segments)
        local current_identity = view and descriptor.adapter:identity(view)
        assert(view and
            current_identity == descriptor.captured_identity and
            descriptor.adapter:contains(view) and
            self.view_mounts[view] == mount.id,
            ('DwarfSpec %s rejected subject control_path=%q mount=%s because ' ..
                'its view is outside the current mount'):format(operation,
                    subject.control_path, tostring(subject.mount_id)))
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
                control_path=subject.control_path,
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
            error(('DwarfSpec subject failure: operation=%q control_path=%q ' ..
                'subject_mount=%s current_mount=%s cause=%s')
                :format(operation, subject.control_path,
                    tostring(subject.mount_id),
                    tostring(mount and mount.id or nil), reported), 2)
        end
        return table.unpack(results, 2, results.n)
    end

    ---Returns a subject for the current component root.
    ---@return table
    function context:root()
        local mount = self:require_current('root')
        return self:new_subject(mount.root, '<root>')
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

    ---Runs a mutating command and optionally waits for its completed render.
    ---@param operation string
    ---@param action function
    ---@param options table|nil
    ---@return any
    function context:mutate(operation, action, options)
        assert(type(operation) == 'string' and operation ~= '',
            'mutation operation name must be a nonempty string')
        assert(type(action) == 'function',
            'mutation action must be a function')
        assert(options == nil or type(options) == 'table',
            'mutation options must be a table')
        options = options or {}
        assert(options.wait_for_render == nil or
            type(options.wait_for_render) == 'boolean',
            'mutation wait_for_render option must be a boolean')
        local wait_for_render = options.wait_for_render ~= false
        local mount = self:require_current(operation)
        local observation
        if self.command_observer then
            observation = self.command_observer.started(operation, {
                mount_id=mount.id,
                control_path=mount.command_subject and
                    mount.command_subject.control_path or '<root>',
            })
        end
        local captured
        if wait_for_render then
            captured = mount.render_tracker:capture()
        end
        local results = table.pack(xpcall(action, debug.traceback))
        if not results[1] then
            if self.command_observer then
                self.command_observer.finished(observation, false, results[2])
            end
            error(self:report_failure(mount, operation, results[2]), 2)
        end
        if wait_for_render then
            local wait_ok, wait_result = xpcall(function()
                return mount.render_tracker:wait_after(captured,
                    operation .. ' render')
            end, debug.traceback)
            if not wait_ok then
                if self.command_observer then
                    self.command_observer.finished(
                        observation, false, wait_result)
                end
                error(self:report_failure(
                    mount, operation, wait_result), 2)
            end
        end
        self:refresh_views(mount)
        if self.command_observer then
            self.command_observer.finished(observation, true)
        end
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
            interaction_target=nil,
            subject_source=nil,
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
            interaction_target=nil,
            subject_source=nil,
            render_tracker=self.render_tracker_factory(),
            adapter=adapter,
            alive=false,
            cleaned=false,
            cleanup_marker=self.cleanup_module.mark(self.cleanup_registry),
            cleanup_entry=nil,
            cleanup_entries={},
            selected_subjects=setmetatable({}, {__mode='k'}),
            owned_views=setmetatable({}, {__mode='k'}),
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
            mount.root = adapter_result.root or prepared.component
            mount.host_screen = adapter_result.host_screen
            mount.interaction_target = adapter_result.interaction_target
            mount.subject_source = adapter_result.subject_source
            assert(type(mount.root) == 'table',
                'component adapter root must be a native component object')
            assert(type(mount.host_screen) == 'table',
                'component adapter must return its owned host screen')
            assert(type(mount.interaction_target) == 'table' and
                type(mount.interaction_target.assert_current) == 'function' and
                type(mount.interaction_target.native_screen) == 'function' and
                type(mount.interaction_target.invalidate) == 'function' and
                type(mount.interaction_target.cleanup) == 'function',
                'component adapter must return a complete interaction target')
            local source_adapter = subject_adapter(mount)
            assert(source_adapter:root() == mount.root,
                'component subject source must use the adapter result root')
            if mount.host_screen then
                self.owned_screens[mount.host_screen] = true
            end
            mount.render_tracker:wait_after(captured, 'component mount render')
            self:refresh_views(mount)
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
        mount.alive = true
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
