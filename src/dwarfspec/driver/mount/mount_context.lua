-- Constructed run-owned mount context facade.

local cleanup_module = require(
    'dwarfspec.driver.mount.mount_cleanup_verification')
local subject_module = require(
    'dwarfspec.driver.mount.mount_subject_resolution')
local command_module = require(
    'dwarfspec.driver.mount.mount_command_execution')
local ownership_module = require(
    'dwarfspec.driver.mount.mount_resource_ownership')
local descriptor_module = require(
    'dwarfspec.driver.mount.mount_descriptor')

local M = {}

---Constructs a proxy that exposes only named state and dependency functions.
---@param context table
---@param field_names string[]
---@param methods table<string, function>|nil
---@return table
local function narrow_scope(context, field_names, methods)
    local fields = {}
    for _, name in ipairs(field_names) do fields[name] = true end
    methods = methods or {}
    return setmetatable({}, {
        __index=function(_, key)
            if methods[key] then return methods[key] end
            if fields[key] then return context[key] end
            return nil
        end,
        __newindex=function(_, key, value)
            assert(fields[key],
                'mount module attempted to mutate undeclared dependency: ' ..
                    tostring(key))
            context[key] = value
        end,
    })
end

---Returns the current mount or raises a command-specific error.
---@param context table
---@param operation string
---@return table
local function require_current(context, operation)
    assert(type(operation) == 'string' and operation ~= '',
        'mount operation name must be a nonempty string')
    assert(context.current and context.current.alive,
        ('DwarfSpec %s requires a current mount; call ' ..
            'ds.mount(component, options) or ' ..
                'ds.mountNativeScreen() first'):format(operation))
    return context.current
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
    assert(type(options.native_render_observer_factory) == 'function',
        'mount context requires a native render observer factory')
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
        native_render_observer_factory=options.native_render_observer_factory,
        failure_reporter=options.failure_reporter,
        command_observer=options.command_observer,
        subject_module=options.subject_module,
        testbed_adapter=options.testbed_adapter,
        testbed_host=options.testbed_host,
        current=nil,
        next_mount_id=0,
        subject_mounts=setmetatable({}, {__mode='k'}),
        subject_commands={},
        view_mounts=setmetatable({}, {__mode='k'}),
        owned_screens=setmetatable({}, {__mode='k'}),
        owned_screen_count=0,
        borrowed_native_screen_count=0,
        native_attachment_count=0,
        native_screen_dismissal_count=0,
    }

    local cleanup = cleanup_module.new(narrow_scope(context, {
        'borrowed_native_screen_count', 'cleanup_module', 'cleanup_registry',
        'current', 'native_attachment_count',
        'native_screen_dismissal_count', 'owned_screen_count', 'owned_screens',
        'subject_module', 'subject_mounts', 'view_mounts',
    }, {
        push_cleanup=function(_, mount, name, action)
            local entry = context.cleanup_module.push(
                context.cleanup_registry, name, action)
            table.insert(mount.cleanup_entries, entry)
            return entry
        end,
    }))
    local commands
    local subjects
    local subject_context = {
        invoke_subject_command=function(_, ...)
            return commands:invoke_subject_command(...)
        end,
        resolve_subject=function(_, ...)
            return subjects:resolve_subject(...)
        end,
    }
    subjects = subject_module.new(narrow_scope(context, {
        'current', 'subject_module', 'subject_mounts', 'view_mounts',
    }, {
        require_current=function(_, operation)
            return require_current(context, operation)
        end,
        subject_context=subject_context,
    }))
    commands = command_module.new(narrow_scope(context, {
        'boundary', 'command_observer', 'current', 'failure_reporter',
        'subject_commands',
    }, {
        new_subject=function(_, ...)
            return subjects:new_subject(...)
        end,
        refresh_views=function(_, ...)
            return subjects:refresh_views(...)
        end,
        require_current=function(_, operation)
            return require_current(context, operation)
        end,
        resolve_subject=function(_, ...)
            return subjects:resolve_subject(...)
        end,
        render={
            capture=function(_, mount)
                return mount.render_tracker:capture()
            end,
            wait_after=function(_, mount, captured, label)
                return mount.render_tracker:wait_after(captured, label)
            end,
        },
    }))
    local ownership = ownership_module.new(narrow_scope(context, {
        'adapter_factory', 'borrowed_native_screen_count', 'boundary',
        'cleanup_module', 'cleanup_registry', 'current',
        'native_attachment_count', 'native_render_observer_factory',
        'next_mount_id', 'owned_screen_count', 'owned_screens',
        'render_tracker_factory', 'run',
    }, {
        cleanup=cleanup,
        subject_adapter=function(_, ...)
            return subjects:adapter_for(...)
        end,
        refresh_views=function(_, ...)
            return subjects:refresh_views(...)
        end,
        report_failure=function(_, ...)
            return commands:report_failure(...)
        end,
        require_current=function(_, operation)
            return require_current(context, operation)
        end,
        root=function()
            return commands:root()
        end,
    }))

    ---Returns exact lifecycle counts for cleanup evidence.
    ---@return table
    function context:cleanup_state()
        return cleanup:cleanup_state()
    end

    ---Executes one retained subject command.
    ---@param subject table
    ---@param operation string
    ---@param ... any
    ---@return any
    function context:invoke_subject_command(subject, operation, ...)
        return commands:invoke_subject_command(subject, operation, ...)
    end

    ---Activates one classified component.
    ---@param component any
    ---@param mount_options table|nil
    ---@return table
    function context:mount(component, mount_options)
        return ownership:mount(component, mount_options)
    end

    ---Mounts one tagged descriptor through a fresh mount-owned TestBed.
    ---@param descriptor table
    ---@param mount_options table|nil
    ---@param testbed_config dwarfspec.TestBedConfig|nil
    ---@return table
    function context:mount_descriptor(descriptor, mount_options, testbed_config)
        assert(not self.current, 'DwarfSpec mount rejected because a mount is still current; call ds.unmount() before creating another mount')
        assert(type(self.testbed_adapter) == 'table' and
            type(self.testbed_adapter.new) == 'function' and
            type(self.testbed_host) == 'table',
            'DwarfSpec descriptor mount requires live TestBed adapter dependencies')
        descriptor = descriptor_module.validate(descriptor)
        assert(testbed_config == nil or type(testbed_config) == 'table',
            'DwarfSpec descriptor TestBed configuration must be a table or nil')
        local TestBed = require('dwarfspec.testbed')
        assert(not TestBed.is_instance(testbed_config),
            'DwarfSpec descriptor mount does not accept a TestBed instance')
        local marker = self.cleanup_module.mark(self.cleanup_registry)
        local bed = self.testbed_adapter.new(testbed_config, self.run,
            self.testbed_host)
        local entries = {}
        local registered, bed_entry = xpcall(function()
            return self.cleanup_module.push(self.cleanup_registry,
                'close descriptor TestBed', function() bed:close() end)
        end, debug.traceback)
        if not registered then
            bed:close()
            error('DwarfSpec descriptor mount failed to register TestBed cleanup: ' ..
                tostring(bed_entry), 2)
        end
        table.insert(entries, bed_entry)
        local ok, result = xpcall(function()
            local component = descriptor_module.resolve(bed, descriptor)
            local classification = self.boundary:classify(component)
            assert(classification.input_form == 'class',
                'DwarfSpec mount descriptor must resolve to a component class')
            return ownership:mount(component, mount_options, {
                cleanup_marker=marker, cleanup_entries=entries})
        end, debug.traceback)
        if ok then return result end
        self.cleanup_module.run_from(self.cleanup_registry, marker,
            'failed descriptor mount')
        error(result, 2)
    end

    ---Returns the current mount owning one raw view.
    ---@param view table
    ---@return table|nil
    function context:mount_for_view(view)
        return subjects:mount_for_view(view)
    end

    ---Attaches one borrowed native screen.
    ---@param attach function
    ---@return table
    function context:mount_native_screen(attach)
        return ownership:mount_native_screen(attach)
    end

    ---Runs one render-aware mutation.
    ---@param operation string
    ---@param action function
    ---@param mutation_options table|nil
    ---@return any
    function context:mutate(operation, action, mutation_options)
        return commands:mutate(operation, action, mutation_options)
    end

    ---Creates one retained subject.
    ---@param view table
    ---@param control_path string|nil
    ---@param path_segments table|nil
    ---@param source table|nil
    ---@return table
    function context:new_subject(view, control_path, path_segments, source)
        return subjects:new_subject(
            view, control_path, path_segments, source)
    end

    ---Registers one cleanup action owned by a mount.
    ---@param mount table
    ---@param name string
    ---@param action function
    ---@return table
    function context:push_cleanup(mount, name, action)
        return ownership:push_cleanup(mount, name, action)
    end

    ---Refreshes adapted views for one mount.
    ---@param mount table
    function context:refresh_views(mount)
        return subjects:refresh_views(mount)
    end

    ---Registers one externally owned subject source.
    ---@param source table
    ---@return table
    function context:register_subject_source(source)
        return subjects:register_subject_source(source)
    end

    ---Enriches one mount operation failure.
    ---@param mount table
    ---@param operation string
    ---@param failure any
    ---@return string
    function context:report_failure(mount, operation, failure)
        return commands:report_failure(mount, operation, failure)
    end

    ---Requires a live current mount.
    ---@param operation string
    ---@return table
    function context:require_current(operation)
        return require_current(context, operation)
    end

    ---Resolves one component-relative control path.
    ---@param control_path string
    ---@return table
    function context:resolve_control_path(control_path)
        return subjects:resolve_control_path(control_path)
    end

    ---Resolves normalized path segments through a selected source.
    ---@param segments table
    ---@param diagnostic_path string
    ---@param source table|nil
    ---@return any
    function context:resolve_path_segments(segments, diagnostic_path, source)
        return subjects:resolve_path_segments(
            segments, diagnostic_path, source)
    end

    ---Reacquires one retained subject.
    ---@param subject table
    ---@param operation string
    ---@return table
    function context:resolve_subject(subject, operation)
        return subjects:resolve_subject(subject, operation)
    end

    ---Returns the current mount root subject.
    ---@return table
    function context:root()
        return commands:root()
    end

    ---Hands the current mount to scoped cleanup.
    function context:unmount()
        return ownership:unmount()
    end

    ---Changes the current owned mount viewport.
    ---@param width integer
    ---@param height integer
    ---@return any
    function context:viewport(width, height)
        return commands:viewport(width, height)
    end

    return context
end

return M
