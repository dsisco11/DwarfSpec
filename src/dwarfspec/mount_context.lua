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
        type(options.boundary.prepare) == 'function',
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
    assert(type(options.subject_module) == 'table' and
        type(options.subject_module.new) == 'function',
        'mount context requires a subject factory')

    local context = {
        run=options.run,
        boundary=options.boundary,
        cleanup_module=options.cleanup_module,
        cleanup_registry=options.cleanup_registry,
        adapter_factory=options.adapter_factory,
        subject_module=options.subject_module,
        current=nil,
        next_mount_id=0,
        subject_mounts=setmetatable({}, {__mode='k'}),
    }

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
    ---@return table
    function context:new_subject(view)
        local mount = self:require_current('subject creation')
        local subject = self.subject_module.new(self, mount, view)
        self.subject_mounts[subject] = mount.id
        mount.selected_subjects[subject] = true
        return subject
    end

    ---Resolves a subject only while its original mount remains current.
    ---@param subject table
    ---@param operation string
    ---@return table
    function context:resolve_subject(subject, operation)
        local mount = self:require_current(operation)
        assert(self.subject_mounts[subject] == mount.id and
            subject.mount_id == mount.id,
            ('DwarfSpec %s rejected a stale subject from mount %s; ' ..
                'current mount is %s'):format(operation,
                    tostring(subject.mount_id), tostring(mount.id)))
        local view = subject._references and subject._references.view
        assert(view, 'DwarfSpec subject native object is no longer available')
        return view
    end

    ---Returns a subject for the current component root.
    ---@return table
    function context:root()
        local mount = self:require_current('root')
        return self:new_subject(mount.root)
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

    ---Replaces any current mount and activates one classified component.
    ---@param component any
    ---@param mount_options table|nil
    ---@return table
    function context:mount(component, mount_options)
        if self.current then self:unmount() end

        local classification = self.boundary:classify(component)
        local adapter = self.adapter_factory(classification.category)
        assert(type(adapter) == 'table' and
            type(adapter.mount) == 'function',
            'component adapter must provide mount() for ' ..
                classification.category)
        local prepared = self.boundary:prepare(component, mount_options)
        self.next_mount_id = self.next_mount_id + 1
        local mount = {
            id=self.next_mount_id,
            category=prepared.category,
            input_form=prepared.input_form,
            component_class=prepared.class,
            root=prepared.component,
            host_screen=nil,
            render_generation=0,
            adapter=adapter,
            active=false,
            cleaned=false,
            cleanup_marker=self.cleanup_module.mark(self.cleanup_registry),
            cleanup_entry=nil,
            cleanup_entries={},
            selected_subjects=setmetatable({}, {__mode='k'}),
            options=prepared.options,
        }
        self.current = mount
        mount.cleanup_entry = self.cleanup_module.push(
            self.cleanup_registry,
            ('unmount component %d'):format(mount.id),
            function() cleanup_mount(self, mount) end)
        table.insert(mount.cleanup_entries, mount.cleanup_entry)

        local ok, result = xpcall(function()
            local adapter_result = adapter:mount(
                mount, prepared, function(name, action)
                return self:push_cleanup(mount, name, action)
            end)
            adapter_result = adapter_result or {}
            assert(type(adapter_result) == 'table',
                'component adapter mount() must return a table or nil')
            assert(type(adapter_result.root or prepared.component) == 'table',
                'component adapter root must be a native component object')
            return adapter_result
        end, debug.traceback)
        if not ok then
            local cleanup_ok, failures = self.cleanup_module.run_from(
                self.cleanup_registry, mount.cleanup_marker,
                'failed component mount')
            local message = 'DwarfSpec mount failed while activating ' ..
                prepared.category .. ' component: ' .. tostring(result)
            if not cleanup_ok then
                message = message .. '; cleanup failed: ' ..
                    format_cleanup_failures(failures)
            end
            error(message, 2)
        end
        mount.root = result.root or prepared.component
        mount.host_screen = result.host_screen
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
