-- Mount allocation, ownership, and explicit unmount handoff.


local M = {}

---Constructs mount ownership with explicitly bounded dependencies.
---@param scope table
---@return table
function M.new(scope)
    local cleanup = assert(scope.cleanup,
        'mount resource ownership requires cleanup services')
    local service = {}
    ---Validates one complete interaction target without taking ownership.
    ---@param interaction_target any
    ---@param label string
    local function validate_interaction_target(interaction_target, label)
        assert(type(interaction_target) == 'table' and
            type(interaction_target.assert_current) == 'function' and
            type(interaction_target.native_screen) == 'function' and
            type(interaction_target.invalidate) == 'function' and
            type(interaction_target.cleanup) == 'function',
            label .. ' must return a complete interaction target')
    end

    ---Registers one cleanup action owned by the current mount.
    ---@param mount table
    ---@param name string
    ---@param action function
    ---@return table
    function service:push_cleanup(mount, name, action)
        assert(self.current == mount and not mount.cleaned,
            'cleanup can only be registered for the current mount')
        local entry = self.cleanup_module.push(self.cleanup_registry,
            name, action)
        table.insert(mount.cleanup_entries, entry)
        return entry
    end
    ---Releases the current mount through scoped LIFO cleanup.
    function service:unmount()
        local mount = self:require_current('unmount')
        local ok, failures = self.cleanup_module.run_from(
            self.cleanup_registry, mount.cleanup_marker,
            'component unmount')
        if not ok then
            error('DwarfSpec unmount cleanup failed: ' ..
                cleanup:format_failures(failures), 2)
        end
    end
    ---Attaches a validated borrowed native screen as the implicit mount.
    ---@param attach function
    ---@return table
    function service:mount_native_screen(attach)
        assert(not self.current,
            ('DwarfSpec mount rejected because mount %d is still current; ' ..
                'call ds.unmount() before creating another mount')
                :format(self.current and self.current.id or -1))
        assert(type(attach) == 'function',
            'native-screen mount requires an attachment factory')

        local attach_ok, attachment = xpcall(attach, debug.traceback)
        if not attach_ok then error(attachment, 2) end
        assert(type(attachment) == 'table',
            'native attachment must return a table')

        self.next_mount_id = self.next_mount_id + 1
        local mount = {
            id=self.next_mount_id,
            run=self.run,
            category='native',
            input_form='borrowed',
            component_class=nil,
            root=attachment.root,
            host_screen=nil,
            pinned_screen=attachment.pinned_screen,
            interaction_target=attachment.interaction_target,
            subject_source=attachment.subject_source,
            subject_sources={},
            render_tracker=nil,
            render_observer=nil,
            adapter=nil,
            alive=false,
            cleaned=false,
            cleanup_marker=nil,
            cleanup_entry=nil,
            cleanup_entries={},
            selected_subjects=setmetatable({}, {__mode='k'}),
            owned_views=setmetatable({}, {__mode='k'}),
            command_subject=nil,
            options={},
            attachment_counted=true,
        }
        self.borrowed_native_screen_count =
            self.borrowed_native_screen_count + 1
        self.native_attachment_count = self.native_attachment_count + 1
        if mount.subject_source then
            mount.subject_sources[mount.subject_source] = true
        end
        mount.refresh_views = function() self:refresh_views(mount) end
        local setup_ok, setup_failure = xpcall(function()
            mount.render_tracker = self.render_tracker_factory()
            mount.cleanup_marker =
                self.cleanup_module.mark(self.cleanup_registry)
        end, debug.traceback)
        if not setup_ok then
            local cleanup_ok, cleanup_failure =
                xpcall(function() cleanup:cleanup_mount(mount) end,
                    debug.traceback)
            local message =
                'DwarfSpec native-screen mount failed to initialize ' ..
                    'run-scoped state: ' .. tostring(setup_failure)
            if not cleanup_ok then
                message = message .. '; direct cleanup failed: ' ..
                    tostring(cleanup_failure)
            end
            error(message, 2)
        end
        local registration_ok, cleanup_entry = xpcall(function()
            return self.cleanup_module.push(
                self.cleanup_registry,
                ('detach native screen %d'):format(mount.id),
                function() cleanup:cleanup_mount(mount) end)
        end, debug.traceback)
        if not registration_ok then
            local cleanup_ok, cleanup_failure =
                xpcall(function() cleanup:cleanup_mount(mount) end,
                    debug.traceback)
            local message =
                'DwarfSpec native-screen mount failed to register ' ..
                    'cleanup: ' .. tostring(cleanup_entry)
            if not cleanup_ok then
                message = message .. '; direct cleanup failed: ' ..
                    tostring(cleanup_failure)
            end
            error(message, 2)
        end
        mount.cleanup_entry = cleanup_entry
        table.insert(mount.cleanup_entries, mount.cleanup_entry)
        local descriptor_registration_ok, descriptor_entry =
            xpcall(function()
                return cleanup:register_subject_release(mount)
            end, debug.traceback)
        if not descriptor_registration_ok then
            local cleanup_ok, failures = self.cleanup_module.run_from(
                self.cleanup_registry, mount.cleanup_marker,
                'failed native subject cleanup registration')
            local message =
                'DwarfSpec native-screen mount failed to register ' ..
                    'subject cleanup: ' .. tostring(descriptor_entry)
            if not cleanup_ok then
                message = message .. '; cleanup failed: ' ..
                    cleanup:format_failures(failures)
            end
            error(message, 2)
        end
        table.insert(mount.cleanup_entries, descriptor_entry)
        self.current = mount

        local ok, root_subject = xpcall(function()
            assert(mount.root ~= nil,
                'native attachment must return its pinned widget root')
            assert(mount.pinned_screen ~= nil,
                'native attachment must return its pinned viewscreen')
            assert(mount.host_screen == nil,
                'native attachment must not return an owned host screen')
            validate_interaction_target(
                mount.interaction_target, 'native attachment')
            local source_adapter = self:subject_adapter(mount)
            assert(source_adapter:root() == mount.root,
                'native subject source must use the pinned widget root')
            local restore = self.native_render_observer_factory(mount)
            assert(type(restore) == 'function',
                'native render observer factory must return a restore function')
            cleanup:register_observer_restore(mount, restore)
            mount.render_observer = restore
            mount.alive = true
            self:refresh_views(mount)
            local captured = mount.render_tracker:capture()
            local capability_ok, capability_failure = xpcall(function()
                mount.interaction_target:invalidate()
                return mount.render_tracker:wait_after(
                    captured, 'native-screen mount render capability check')
            end, debug.traceback)
            if not capability_ok then
                error(
                    'DwarfSpec native-screen mount render capability check ' ..
                        'failed: ' .. tostring(capability_failure), 0)
            end
            return self:root()
        end, debug.traceback)
        if not ok then
            local cleanup_ok, failures = self.cleanup_module.run_from(
                self.cleanup_registry, mount.cleanup_marker,
                'failed native attachment')
            local message =
                'DwarfSpec native-screen mount failed while attaching: ' ..
                    tostring(root_subject)
            if not cleanup_ok then
                message = message .. '; cleanup failed: ' ..
                    cleanup:format_failures(failures)
            end
            error(message, 2)
        end
        return root_subject
    end

    ---Activates one classified component when no mount is current.
    ---@param component any
    ---@param mount_options table|nil
    ---@return table
    function service:mount(component, mount_options, setup)
        assert(not self.current,
            ('DwarfSpec mount rejected because mount %d is still current; ' ..
                'call ds.unmount() before creating another mount')
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
            pinned_screen=nil,
            interaction_target=nil,
            subject_source=nil,
            subject_sources={},
            command_subject=nil,
        }
        local prepare_ok, prepared = xpcall(function()
            return self.boundary:prepare(component, mount_options)
        end, debug.traceback)
        if not prepare_ok then
            error(self:report_failure(mount_attempt, 'mount', prepared), 2)
        end
        setup = setup or {}
        local mount = {
            id=mount_attempt.id,
            run=self.run,
            category=prepared.category,
            input_form=prepared.input_form,
            component_class=prepared.class,
            root=prepared.component,
            host_screen=nil,
            pinned_screen=nil,
            interaction_target=nil,
            subject_source=nil,
            subject_sources={},
            render_tracker=self.render_tracker_factory(),
            render_observer=nil,
            adapter=adapter,
            alive=false,
            cleaned=false,
            cleanup_marker=setup.cleanup_marker or self.cleanup_module.mark(self.cleanup_registry),
            cleanup_entry=nil,
            cleanup_entries=setup.cleanup_entries or {},
            selected_subjects=setmetatable({}, {__mode='k'}),
            owned_views=setmetatable({}, {__mode='k'}),
            command_subject=nil,
            options=prepared.options,
        }
        mount.refresh_views = function() self:refresh_views(mount) end
        self.current = mount
        local registration_ok, cleanup_entry = xpcall(function()
            return self.cleanup_module.push(
                self.cleanup_registry,
                ('unmount component %d'):format(mount.id),
                function() cleanup:cleanup_mount(mount) end)
        end, debug.traceback)
        if not registration_ok then
            local cleanup_ok, cleanup_failure = xpcall(function()
                cleanup:cleanup_mount(mount)
            end, debug.traceback)
            local message = 'DwarfSpec mount failed to register cleanup: ' ..
                tostring(cleanup_entry)
            if not cleanup_ok then
                message = message .. '; direct cleanup failed: ' ..
                    tostring(cleanup_failure)
            end
            error(message, 2)
        end
        mount.cleanup_entry = cleanup_entry
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
            assert(mount.root ~= nil,
                'component adapter root must be a native component object')
            assert(type(mount.host_screen) == 'table',
                'component adapter must return its owned host screen')
            validate_interaction_target(
                mount.interaction_target, 'component adapter')
            local source_adapter = self:subject_adapter(mount)
            mount.subject_sources[mount.subject_source] = true
            assert(source_adapter:root() == mount.root,
                'component subject source must use the adapter result root')
            if mount.host_screen then
                self.owned_screens[mount.host_screen] = true
                self.owned_screen_count = self.owned_screen_count + 1
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
                    cleanup:format_failures(failures)
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
                    cleanup:format_failures(failures)
            end
            error(message, 2)
        end
        return root_subject
    end
    return setmetatable(service, {__index=scope, __newindex=scope})
end

return M
