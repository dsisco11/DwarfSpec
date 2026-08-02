-- Host runtime assembly for one admitted service run.

local M = {}

---Initializes a run with its cleanup, scheduler, and event-publisher dependencies.
---@param run table
---@param package_root string
---@param project_root string
---@param options table
---@param dependencies table
function M.initialize(run, package_root, project_root, options, dependencies)
    local cleanup = dependencies.load_module(package_root, 'dwarfspec.host.execution.cleanup')
    local created_ms = dependencies.now_ms()
    run.package_root, run.project_root, run.options = package_root, project_root, options
    assert(type(dependencies.ds_factory) == 'table' and
        type(dependencies.ds_factory.new) == 'function',
        'run assembly requires an injected dwarfspec.ds factory')
    run.ds_factory = dependencies.ds_factory
    run.state_changed_ms, run.created_ms, run.created_frame = created_ms, created_ms, dependencies.current_frame()
    for _, field in ipairs({'started_ms','started_frame','finished_ms','finished_frame','last_status_poll_ms','last_status_poll_frame','current_test','coroutine','scheduled_timeout_id','outstanding_wait','cleanup_registry','cleanup_reason','mount_cleanup_probe','mount_cleanup_state','module_environment_audit','scheduler_module','scheduler'}) do run[field] = nil end
    run.output_lines, run.failure_details, run.discovered_files, run.recorded_cleanup_failures = {}, {}, {}, {}
    run.cleanup_module, run.cleanup_failure_reported_by_busted, run.suspended, run.terminal_observed = cleanup, false, false, false
    assert(type(run.lease_check_frames) == 'number' and run.lease_check_frames >= 1 and run.lease_check_frames % 1 == 0, 'lease check interval must be a positive integer')
    run.cleanup_registry = cleanup.new(run, dependencies.is_active)
    run.event_publisher = dependencies.create_event_publisher(run, {
        now_ms=dependencies.now_ms,
        publish_active_event=dependencies.publish_active_event,
    })
end

---Creates the coroutine scheduler and its host timing adapters for a run.
---@param package_root string
---@param run table
---@param dependencies table
---@return table, table
function M.create_scheduler(package_root, run, dependencies)
    local scheduler_module = dependencies.load_scheduler(package_root)
    local scheduler = scheduler_module.new(run, {
        is_current=dependencies.is_current,
        schedule_timeout=dependencies.schedule_frames,
        schedule_tick_timeout=dependencies.schedule_ticks,
        cancel_timeout=dependencies.cancel_timeout,
        now_ms=dependencies.now_ms,
        diagnostics=dependencies.diagnostics,
        on_complete=dependencies.on_complete,
    })
    run.scheduler_module = scheduler_module
    run.scheduler = scheduler
    return scheduler_module, scheduler
end

---Schedules deferred activation and reports native timer rejection.
---@param run table
---@param dependencies table
---@return any
function M.schedule_activation(run, dependencies)
    local timeout_id = dependencies.schedule_frames(
        run.options.defer_frames, dependencies.begin_run)
    if not timeout_id then
        dependencies.fail_run('DFHack rejected the automation startup timer')
        return nil
    end
    run.scheduled_timeout_id = timeout_id
    return timeout_id
end

return M
