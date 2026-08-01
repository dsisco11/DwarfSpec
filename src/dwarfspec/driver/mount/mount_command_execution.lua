-- Mounted command execution and render-aware mutation waits.

local M = {}

---Constructs command execution with explicitly bounded dependencies.
---@param scope table
---@return table
function M.new(scope)
    local service = {}
    ---Adds bounded mount diagnostics to an operational failure when available.
    ---@param mount table
    ---@param operation string
    ---@param failure any
    ---@return string
    function service:report_failure(mount, operation, failure)
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
    function service:require_current(operation)
        assert(type(operation) == 'string' and operation ~= '',
            'mount operation name must be a nonempty string')
        assert(self.current and self.current.alive,
            ('DwarfSpec %s requires a current mount; call ' ..
                'ds.mount(component, options) or ' ..
                    'ds.mountNativeScreen() first'):format(operation))
        return self.current
    end
    ---Executes one subject command immediately with retained selection context.
    ---@param subject table
    ---@param operation string
    ---@param ... any
    ---@return any
    function service:invoke_subject_command(subject, operation, ...)
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

    ---Returns a subject for the current mount's default root.
    ---@return table
    function service:root()
        local mount = self:require_current('root')
        return self:new_subject(mount.root, '<root>')
    end

    ---Runs a mutating command and optionally waits for its completed render.
    ---@param operation string
    ---@param action function
    ---@param options table|nil
    ---@return any
    function service:mutate(operation, action, options)
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
            captured = self.render:capture(mount)
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
                return self.render:wait_after(mount, captured,
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
    function service:viewport(width, height)
        local mount = self:require_current('viewport')
        assert(mount.host_screen ~= nil,
            'DwarfSpec viewport is unavailable for a non-owning native-screen ' ..
                'mount')
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
    return setmetatable(service, {__index=scope, __newindex=scope})
end

return M
