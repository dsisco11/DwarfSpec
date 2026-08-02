-- Mount teardown coordination and exact cleanup-state evidence.

local M = {}

---Constructs cleanup verification with explicitly bounded dependencies.
---@param scope table
---@return table
function M.new(scope)
    local service = {}

    ---Formats cleanup failures without discarding their registered names.
    ---@param failures table[]
    ---@return string
    function service:format_failures(failures)
        local messages = {}
        for _, failure in ipairs(failures) do
            table.insert(messages, failure.name .. ': ' .. failure.message)
        end
        return table.concat(messages, '; ')
    end

    ---Releases retained descriptors without dereferencing adapted objects.
    ---@param mount table
    ---@return boolean
    function service:release_subjects(mount)
        local released = false
        local failures = {}
        for subject in pairs(mount.selected_subjects) do
            self.subject_mounts[subject] = nil
            local ok, failure = xpcall(function()
                self.subject_module.release(subject)
            end, debug.traceback)
            if not ok then table.insert(failures, tostring(failure)) end
            released = true
        end
        mount.command_subject = nil
        mount.selected_subjects = setmetatable({}, {__mode='k'})
        if #failures > 0 then
            error('subject descriptor cleanup failed: ' ..
                table.concat(failures, '; '), 0)
        end
        return released
    end

    ---Runs adapter teardown and always drops mount-owned references.
    ---@param mount table
    function service:cleanup_mount(mount)
        if mount.cleaned then return end
        local failures = {}

        ---Runs one callback and retains its traceback on failure.
        ---@param callback function
        local function attempt(callback)
            local ok, message = xpcall(callback, debug.traceback)
            if not ok then table.insert(failures, tostring(message)) end
        end

        if mount.adapter and type(mount.adapter.unmount) == 'function' then
            attempt(function() mount.adapter:unmount(mount) end)
        end
        if mount.adapter and type(mount.adapter.settle) == 'function' then
            attempt(function() mount.adapter:settle(mount) end)
        end
        attempt(function() self:release_subjects(mount) end)
        local cleaned_adapters = {}
        local sources = mount.subject_sources or {}
        if mount.subject_source then sources[mount.subject_source] = true end
        for source in pairs(sources) do
            local adapter = source and source.adapter or nil
            if adapter and not cleaned_adapters[adapter] and
                    type(adapter.cleanup) == 'function' then
                cleaned_adapters[adapter] = true
                attempt(function() adapter:cleanup() end)
            end
        end
        if mount.interaction_target and
                type(mount.interaction_target.cleanup) == 'function' then
            attempt(function() mount.interaction_target:cleanup() end)
        end

        if mount.host_screen and self.owned_screens[mount.host_screen] then
            self.owned_screens[mount.host_screen] = nil
            self.owned_screen_count =
                math.max(0, self.owned_screen_count - 1)
        end
        if mount.attachment_counted then
            self.borrowed_native_screen_count =
                math.max(0, self.borrowed_native_screen_count - 1)
            mount.attachment_counted = false
        end
        mount.cleaned = true
        mount.alive = false
        mount.root = nil
        mount.host_screen = nil
        mount.pinned_screen = nil
        mount.interaction_target = nil
        mount.subject_source = nil
        mount.subject_sources = {}
        mount.render_observer = nil
        mount.adapter = nil
        mount.cleanup_entry = nil
        mount.cleanup_entries = {}
        mount.refresh_views = nil
        for view in pairs(mount.owned_views) do
            if self.view_mounts[view] == mount.id then
                self.view_mounts[view] = nil
            end
        end
        mount.owned_views = setmetatable({}, {__mode='k'})
        if self.current == mount then self.current = nil end
        if #failures > 0 then
            error('component adapter cleanup failed: ' ..
                table.concat(failures, '; '), 0)
        end
    end

    ---Registers native subject release as an independently drainable layer.
    ---@param mount table
    ---@return table
    function service:register_subject_release(mount)
        return self.cleanup_module.push(
            self.cleanup_registry,
            ('clear native subject descriptors %d'):format(mount.id),
            function() self:release_subjects(mount) end)
    end

    ---Registers observer restoration and restores if registration fails.
    ---@param mount table
    ---@param restore function
    ---@return table
    function service:register_observer_restore(mount, restore)
        local registered, entry = xpcall(function()
            return self:push_cleanup(
                mount,
                ('restore native render observation %d'):format(mount.id),
                restore)
        end, debug.traceback)
        if registered then return entry end

        local restored, restore_failure = xpcall(restore, debug.traceback)
        local message =
            'native render observer cleanup registration failed: ' ..
                tostring(entry)
        if not restored then
            message = message .. '; direct restoration failed: ' ..
                tostring(restore_failure)
        end
        error(message, 0)
    end

    ---Returns plain lifecycle counts for terminal cleanup evidence.
    ---@return table
    function service:cleanup_state()
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
            owned_screen_count=self.owned_screen_count,
            borrowed_native_screen_count=self.borrowed_native_screen_count,
            native_attachment_count=self.native_attachment_count,
            native_screen_dismissal_count=self.native_screen_dismissal_count,
            subject_count=subject_count,
        }
    end

    return setmetatable(service, {__index=scope, __newindex=scope})
end

return M
