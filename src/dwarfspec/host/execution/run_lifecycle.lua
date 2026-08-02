-- Native run startup, cleanup, finalization, and abort lifecycle.

local M = {}

---Creates lifecycle operations from explicit host dependencies.
---@param dependencies table
---@return table
function M.new(dependencies)
    for _, name in ipairs({
        'publish_event', 'begin_cleanup', 'complete_active', 'activate_next',
        'cancel_timeout', 'now_ms', 'current_frame', 'assemble_scheduler',
        'execute_suite',
    }) do
        assert(type(dependencies[name]) == 'function',
            'run lifecycle requires dependency: ' .. name)
    end
    assert(type(dependencies.states) == 'table',
        'run lifecycle requires terminal states')

    local lifecycle = {}

    ---Records previously unreported cleanup failures on a run.
    ---@param run table
    ---@param failures table[]
    local function record_cleanup_failures(run, failures)
        for _, failure in ipairs(failures) do
            local failure_key = failure.id or failure
            if not run.recorded_cleanup_failures[failure_key] then
                run.recorded_cleanup_failures[failure_key] = true
                dependencies.publish_event(run, dependencies.events.cleanup_failed, {
                    action_name=failure.name,
                    reason=failure.reason,
                    message=failure.message,
                    trace=failure.message,
                })
                if not failure.reported_by_busted then
                    local message = ('cleanup %s failed during %s: %s')
                        :format(failure.name, failure.reason, failure.message)
                    table.insert(run.output_lines, 'CLEANUP_ERROR ' .. message)
                    table.insert(run.failure_details, {
                        kind='error',
                        name='automation cleanup: ' .. failure.name,
                        message=message,
                        trace=failure.message,
                    })
                end
            end
        end
    end

    ---Cancels asynchronous work and drains all cleanup actions for a run.
    ---@param run table
    ---@param reason string
    ---@return boolean
    function lifecycle.clean(run, reason)
        if run.focus_lifecycle ~= nil then
            run.focus_lifecycle.clear()
            run.focus_lifecycle = nil
        end
        if run.scheduler then
            run.scheduler_module.cancel(run.scheduler, reason)
            run.scheduler.owner = nil
            run.scheduler = nil
        end
        dependencies.cancel_timeout(run.scheduled_timeout_id)
        run.scheduled_timeout_id = nil
        local ok = run.cleanup_module.run(run.cleanup_registry, reason)
        run.coroutine = nil
        run.suspended = false

        local mount_state
        local mount_ok = true
        if run.mount_cleanup_probe then
            local probe_ok, result = pcall(run.mount_cleanup_probe)
            if probe_ok and type(result) == 'table' then
                mount_state = result
                mount_ok = result.current_mount_id == nil and
                    result.active_screen_count == 0 and
                    (result.tracked_screen_count or 0) == 0 and
                    (result.owned_screen_count or 0) == 0 and
                    (result.borrowed_native_screen_count or 0) == 0 and
                    (result.native_screen_dismissal_count or 0) == 0 and
                    result.subject_count == 0 and
                    result.pointer_active ~= true and
                    result.button_state_active ~= true and
                    result.game_pause_state_active ~= true and
                    result.game_speed_active ~= true and
                    result.render_observer_active ~= true
            else
                mount_ok = false
                mount_state = {probe_error=tostring(result)}
            end
            run.mount_cleanup_probe = nil
        end
        if mount_state then mount_state.verified = mount_ok end
        run.mount_cleanup_state = mount_state
        run.mount_cleanup_verified = mount_ok

        local module_audit = run.module_environment_audit
        local module_environment_ok = module_audit == nil or
            module_audit.restored == true and module_audit.path_restored == true
        run.cleanup_confirmed = ok and #run.cleanup_registry.failures == 0 and
            mount_ok and module_environment_ok and
            run.cleanup_module.pending_count(run.cleanup_registry) == 0 and
            run.outstanding_wait == nil and run.coroutine == nil and
            run.scheduler == nil and run.scheduled_timeout_id == nil
        run.cleanup_reason = reason
        record_cleanup_failures(run, run.cleanup_registry.failures)

        local function report_verification_failure(name, message, trace)
            table.insert(run.output_lines, 'CLEANUP_ERROR ' .. message)
            table.insert(run.failure_details, {
                kind='error', name='automation cleanup: ' .. name,
                message=message, trace=trace,
            })
            dependencies.publish_event(run, dependencies.events.cleanup_failed, {
                action_name=name, reason=reason, message=message, trace=trace,
            })
        end
        if not mount_ok then
            report_verification_failure('mount lifecycle verification',
                'mount lifecycle verification failed during ' .. reason,
                mount_state and mount_state.probe_error or nil)
        end
        if not module_environment_ok then
            report_verification_failure('project module environment',
                'project module environment was not restored during ' .. reason)
        end
        dependencies.publish_event(run, dependencies.events.cleanup_finished, {
            cleanup_confirmed=run.cleanup_confirmed,
            mount_cleanup_verified=mount_ok,
        })
        return run.cleanup_confirmed
    end

    ---Finalizes a current run from suite counts or an uncaught host failure.
    ---@param registry table
    ---@param run table
    ---@param ok boolean
    ---@param host_error any
    function lifecycle.finalize(registry, run, ok, host_error)
        if registry.active_run_id ~= run.run_id or
                registry.runs[run.run_id] ~= run or run.terminal then
            return
        end
        dependencies.begin_cleanup(run, 'suite completion')
        if not ok then
            run.host_error = tostring(host_error)
            if run.coroutine ~= nil then
                run.host_trace = debug.traceback(run.coroutine,
                    tostring(host_error))
            else
                run.host_trace = debug.traceback(tostring(host_error))
            end
            run.counts.errors = run.counts.errors + 1
            run.totals.errors = run.totals.errors + 1
            table.insert(run.output_lines, 'HOST_ERROR ' .. run.host_error)
        end
        local cleanup_ok = lifecycle.clean(run, 'suite completion')
        if not cleanup_ok and not run.cleanup_failure_reported_by_busted then
            run.counts.errors = run.counts.errors + 1
            run.totals.errors = run.totals.errors + 1
        end
        run.finished_ms = dependencies.now_ms()
        run.finished_frame = dependencies.current_frame()
        local terminal_state = dependencies.states.failed
        if ok and cleanup_ok and run.totals.failures == 0 and
                run.totals.errors == 0 then
            terminal_state = dependencies.states.passed
        end
        dependencies.complete_active(run, terminal_state, cleanup_ok,
            run.cleanup_reason)
        run.terminal_observed = false
        dependencies.activate_next()
    end

    ---Starts suite execution when the queued generation still owns the run.
    ---@param package_root string
    ---@param project_root string
    ---@param registry table
    ---@param run table
    function lifecycle.begin(package_root, project_root, registry, run)
        if registry.active_run_id ~= run.run_id or
                registry.runs[run.run_id] ~= run or
                run.state ~= dependencies.states.starting then
            return
        end
        run.scheduled_timeout_id = nil
        dependencies.start_active(run)
        run.started_ms = dependencies.now_ms()
        run.started_frame = dependencies.current_frame()
        local scheduler_module, scheduler = dependencies.assemble_scheduler(
            package_root, run, {
                is_current=function()
                return registry.active_run_id == run.run_id and
                    registry.runs[run.run_id] == run and
                    run.state == dependencies.states.running
                end,
                on_complete=function(ok, host_error)
                    lifecycle.finalize(registry, run, ok, host_error)
                end,
            })
        run.coroutine = coroutine.create(function()
            dependencies.execute_suite(package_root, project_root, run,
                scheduler_module, scheduler)
        end)
        scheduler_module.bind(scheduler, run.coroutine)
        local ok, yielded = coroutine.resume(run.coroutine)
        if ok and coroutine.status(run.coroutine) ~= 'dead' then
            if not scheduler_module.owns_yield(scheduler, yielded) then
                lifecycle.finalize(registry, run, false,
                    'automation suite yielded outside the owned scheduler')
                return
            end
            run.suspended = true
            return
        end
        lifecycle.finalize(registry, run, ok, yielded)
    end

    ---Aborts a run for a host-owned reason and performs emergency cleanup.
    ---@param registry table
    ---@param run table
    ---@param reason string
    ---@return table
    function lifecycle.abort(registry, run, reason)
        dependencies.publish_event(run, dependencies.events.run_aborted,
            {reason=reason})
        dependencies.begin_cleanup(run, reason)
        local cleanup_ok = lifecycle.clean(run, reason)
        if not cleanup_ok and not run.cleanup_failure_reported_by_busted then
            run.counts.errors = run.counts.errors + 1
            run.totals.errors = run.totals.errors + 1
        end
        run.finished_ms = dependencies.now_ms()
        run.finished_frame = dependencies.current_frame()
        table.insert(run.output_lines, 'ABORTED ' .. reason)
        dependencies.complete_active(run, dependencies.states.aborted,
            cleanup_ok, reason)
        run.terminal_observed = false
        dependencies.activate_next()
        return run
    end

    return lifecycle
end

return M
