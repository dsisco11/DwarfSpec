-- Sole mutation and protocol-event authority for scheduler state.

local events = require('dwarfspec.protocol.events')
local EventType = require('dwarfspec.protocol.enums.event_types')
local RunState = require('dwarfspec.protocol.enums.run_states')
local FailureKind = require('dwarfspec.protocol.enums.scheduler_failure_kinds')
local validation = require('dwarfspec.host.service.scheduler.request_validation')

local M = {}
local ACTIVE = {[RunState.STARTING]=true, [RunState.RUNNING]=true,
    [RunState.CLEANING]=true}
local TERMINAL = {[RunState.PASSED]=true, [RunState.FAILED]=true,
    [RunState.ABORTED]=true, [RunState.CANCELLED]=true}

---Commits one fully validated queued record to the registry.
function M.queue(registry, project, run, timestamp_ms)
    events.publish(run.event_journal, EventType.RUN_QUEUED, {
        selection=run.selection, queue_admitted_ms=timestamp_ms,
        owner_kind=run.owner_kind}, timestamp_ms)
    if registry.quarantine.active then
        events.publish(run.event_journal, EventType.SCHEDULER_BLOCKED, {
            kind=FailureKind.EXECUTOR_QUARANTINED,
            reason=registry.quarantine.reason,
            blocking_run_id=registry.quarantine.run_id,
            blocking_generation=registry.quarantine.generation}, timestamp_ms)
    end
    registry.generation = run.generation
    registry.runs[run.run_id] = run
    table.insert(registry.queue, run.run_id)
    project.outstanding_run_id = run.run_id
    project.request_keys = project.request_keys or {}
    if run.request_key then project.request_keys[run.request_key] = run.run_id end
end

---Rejects the FIFO head before native execution begins.
function M.reject_activation(registry, run, reason, timestamp_ms)
    assert(registry.queue[1] == run.run_id,
        'activation rejection does not target the FIFO head')
    table.remove(registry.queue, 1)
    run.state, run.terminal, run.finished_at_ms =
        RunState.FAILED, true, timestamp_ms
    run.queue_lease.active = false
    run.cleanup_confirmed = true
    run.cleanup_reason = 'native execution was not started'
    events.publish(run.event_journal, EventType.SCHEDULER_BLOCKED,
        {kind=FailureKind.ACTIVATION_INVALID, reason=reason}, timestamp_ms)
    events.publish(run.event_journal, EventType.RUN_FINISHED, {
        terminal_state=RunState.FAILED, totals=run.totals,
        cleanup_required=false, cleanup_confirmed=true}, timestamp_ms)
    registry.latest_terminal_results[run.project_id] = run.run_id
end

---Activates the FIFO head and transfers its queue lease to execution.
function M.activate(registry, run, timestamp_ms)
    assert(registry.active_run_id == nil and registry.queue[1] == run.run_id,
        'activation requires the idle FIFO head')
    table.remove(registry.queue, 1)
    run.state, run.activated_at_ms = RunState.STARTING, timestamp_ms
    run.queue_wait_ms = timestamp_ms - run.submitted_at_ms
    run.queue_lease.active = false
    run.execution_lease.active = true
    run.execution_lease.renewed_at_ms = timestamp_ms
    run.execution_lease.expires_at_ms = timestamp_ms + run.execution_lease.timeout_ms
    run.execution_lease.expiring = nil
    registry.active_run_id = run.run_id
    events.publish(run.event_journal, EventType.RUN_ACTIVATED,
        {queue_wait_ms=run.queue_wait_ms}, timestamp_ms)
end

---Moves an active generation from starting to running.
function M.start_active(registry, run_id, generation, payload, context)
    assert(registry.active_run_id == run_id,
        'active executor identity does not match start')
    local run = assert(registry.runs[run_id],
        'active executor references an unknown run')
    validation.run_identity(registry, run)
    assert(run.generation == generation,
        'active executor generation does not match start')
    assert(run.state == RunState.STARTING and not run.terminal,
        'active executor run is not starting')
    events.validate_payload(EventType.RUN_STARTED, payload)
    local timestamp_ms = validation.current_time(context)
    run.state, run.started_at_ms = RunState.RUNNING, timestamp_ms
    events.publish(run.event_journal, EventType.RUN_STARTED, payload, timestamp_ms)
    return run
end

---Moves an active generation into cleanup.
function M.begin_cleanup(registry, run_id, generation, reason,
        pending_action_count, context)
    assert(registry.active_run_id == run_id,
        'active executor identity does not match cleanup')
    local run = assert(registry.runs[run_id],
        'active executor references an unknown run')
    validation.run_identity(registry, run)
    assert(run.generation == generation,
        'active executor generation does not match cleanup')
    assert((run.state == RunState.STARTING or run.state == RunState.RUNNING) and
        not run.terminal,
        'active executor run cannot enter cleanup from its current state')
    local payload = {reason=reason, pending_action_count=pending_action_count}
    events.validate_payload(EventType.CLEANUP_STARTED, payload)
    local timestamp_ms = validation.current_time(context)
    run.state, run.execution_lease.active = RunState.CLEANING, false
    run.execution_lease.expiring = nil
    events.publish(run.event_journal, EventType.CLEANUP_STARTED,
        payload, timestamp_ms)
    return run
end

---Publishes a generation-guarded event for the active executor.
function M.publish_active_event(registry, run_id, generation, event_type,
        payload, context)
    assert(registry.active_run_id == run_id,
        'event publisher no longer owns the active executor')
    local run = assert(registry.runs[run_id],
        'event publisher references an unknown run')
    validation.run_identity(registry, run)
    assert(run.generation == generation,
        'event publisher generation does not match active run')
    assert(ACTIVE[run.state] and not run.terminal,
        'event publisher run is not active')
    return events.publish(run.event_journal, event_type, payload,
        validation.current_time(context))
end

---Cancels one queued run without native cleanup.
function M.cancel_queued(registry, run, reason, owner, timestamp_ms)
    local queue_index
    for index, queued_id in ipairs(registry.queue) do
        if queued_id == run.run_id then queue_index = index break end
    end
    assert(queue_index, 'queued run is missing from scheduler FIFO')
    table.remove(registry.queue, queue_index)
    run.state, run.terminal, run.finished_at_ms =
        RunState.CANCELLED, true, timestamp_ms
    run.queue_lease.active = false
    run.cleanup_confirmed = true
    run.cleanup_reason = 'native execution was not started'
    run.terminal_reason = reason
    events.publish(run.event_journal, EventType.RUN_CANCELLED,
        {reason=reason, owner=owner}, timestamp_ms)
    events.publish(run.event_journal, EventType.RUN_FINISHED, {
        terminal_state=RunState.CANCELLED, totals=run.totals,
        cleanup_required=false, cleanup_confirmed=true}, timestamp_ms)
    registry.latest_terminal_results[run.project_id] = run.run_id
    return {cancelled=true, identity=validation.public_identity(run), run=run}
end

---Renews a selected lease at a validated timestamp.
function M.renew_lease(lease, timestamp_ms)
    assert(lease.active and not lease.expiring, 'run lease is not active')
    assert(timestamp_ms < lease.expires_at_ms, 'run lease has already expired')
    lease.renewed_at_ms = timestamp_ms
    lease.expires_at_ms = timestamp_ms + lease.timeout_ms
end

---Renews a service-owned heartbeat lease at a validated timestamp.
function M.heartbeat(lease, timestamp_ms)
    lease.renewed_at_ms = timestamp_ms
    lease.expires_at_ms = timestamp_ms + lease.timeout_ms
end

---Marks a queue lease expired before its cancellation transition.
function M.mark_queue_expired(run)
    run.queue_lease.expired = true
end

---Marks an active execution lease as claimed for expiry handling.
function M.claim_expired(run)
    run.execution_lease.active = false
    run.execution_lease.expired = true
    run.execution_lease.expiring = true
end

---Invalidates the current lease timer generation and detaches its handle.
---@param run table
---@return any
function M.detach_lease_timer(run)
    local timer_id = run.lease_timer_id
    run.lease_timer_id = nil
    run.lease_timer_generation = (run.lease_timer_generation or 0) + 1
    return timer_id
end

---Attaches one scheduler-owned timer handle to its exact generation.
---@param run table
---@param timer_id any
function M.attach_lease_timer(run, timer_id)
    assert(timer_id ~= nil, 'automation service lease timer was rejected')
    run.lease_timer_id = timer_id
end

---Clears the fired timer handle without advancing its generation.
---@param run table
function M.clear_fired_lease_timer(run)
    run.lease_timer_id = nil
end

---Records a lease-timer callback failure for service diagnostics.
---@param run table
---@param failure any
function M.record_lease_timer_error(run, failure)
    run.lease_timer_error = tostring(failure)
end

---Finishes and releases an active executor generation.
function M.finish_active(registry, run_id, generation, terminal_state,
        cleanup_confirmed, reason, context)
    assert(TERMINAL[terminal_state] and terminal_state ~= RunState.CANCELLED,
        'active run terminal state must be passed, failed, or aborted')
    assert(type(cleanup_confirmed) == 'boolean',
        'active run cleanup confirmation must be boolean')
    if reason then assert(type(reason) == 'string' and reason ~= '' and
        #reason <= 1024,
        'active completion reason must be a nonempty bounded string') end
    assert(registry.active_run_id == run_id,
        'active executor identity does not match completion')
    local run = assert(registry.runs[run_id],
        'active executor references an unknown run')
    validation.run_identity(registry, run)
    assert(run.generation == generation,
        'active executor generation does not match completion')
    assert(not run.terminal and ACTIVE[run.state],
        'active executor run is not in an executable state')
    local timestamp_ms = validation.current_time(context)
    run.state, run.terminal, run.finished_at_ms = terminal_state, true, timestamp_ms
    run.execution_lease.active = false
    run.cleanup_confirmed, run.cleanup_reason = cleanup_confirmed, reason
    events.publish(run.event_journal, EventType.RUN_FINISHED, {
        terminal_state=terminal_state, totals=run.totals,
        cleanup_required=true, cleanup_confirmed=cleanup_confirmed}, timestamp_ms)
    registry.active_run_id = nil
    registry.latest_terminal_results[run.project_id] = run.run_id
    if not cleanup_confirmed then
        local quarantine_reason = reason or 'active run cleanup was not confirmed'
        registry.quarantine = {active=true, reason=quarantine_reason,
            run_id=run_id, generation=generation}
        for _, queued_id in ipairs(registry.queue) do
            events.publish(registry.runs[queued_id].event_journal,
                EventType.SCHEDULER_BLOCKED, {
                    kind=FailureKind.EXECUTOR_QUARANTINED,
                    reason=quarantine_reason, blocking_run_id=run_id,
                    blocking_generation=generation}, timestamp_ms)
        end
    end
    return {finished=true, identity=validation.public_identity(run), run=run}
end

---Clears scheduler quarantine after policy verification succeeds.
function M.clear_quarantine(registry) registry.quarantine = {active=false} end

---Releases a terminal project's reservation through acknowledgement.
function M.acknowledge(registry, run, timestamp_ms)
    run.acknowledged, run.acknowledged_at_ms = true, timestamp_ms
    registry.projects[run.project_id].outstanding_run_id = nil
end

---Records operator discard and releases the project reservation.
function M.discard(registry, run, reason, authority, timestamp_ms)
    events.publish(run.event_journal, EventType.DIAGNOSTIC_RECORDED,
        {kind='operator_discard', content={reason=reason,
            authority=authority}}, timestamp_ms)
    run.discarded, run.discarded_at_ms, run.discard_reason =
        true, timestamp_ms, reason
    registry.projects[run.project_id].outstanding_run_id = nil
end

---Records an authorized operator action in a run journal.
function M.operator_diagnostic(run, kind, reason, authority, timestamp_ms)
    events.publish(run.event_journal, EventType.DIAGNOSTIC_RECORDED,
        {kind=kind, content={reason=reason, authority=authority}}, timestamp_ms)
end

return M
