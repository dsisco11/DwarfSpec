-- FIFO selection, activation, cancellation, and queue-expiry policy.

local events = require('dwarfspec.protocol.events')
local EventType = require('dwarfspec.protocol.enums.event_types')
local OwnerKind = require('dwarfspec.protocol.enums.owner_kinds')
local projects = require('dwarfspec.host.service.projects')
local RunState = require('dwarfspec.protocol.enums.run_states')
local FailureKind = require('dwarfspec.protocol.enums.scheduler_failure_kinds')
local transitions = require('dwarfspec.host.service.scheduler.transitions')
local validation = require('dwarfspec.host.service.scheduler.request_validation')

local M = {}
local ACTIVE = {[RunState.STARTING]=true, [RunState.RUNNING]=true,
    [RunState.CLEANING]=true}

---Validates that a queued run remains compatible with its project.
local function revalidate(registry, run, context)
    local project = registry.projects[run.project_id]
    assert(type(project) == 'table', 'owning project is no longer registered')
    assert(project.outstanding_run_id == run.run_id,
        'owning project no longer references the queued run')
    assert(project.client_compatibility.protocol == registry.protocol_version,
        'owning project protocol is no longer compatible')
    assert(project.client_compatibility.package_version == registry.package_version,
        'owning project package version is no longer compatible')
    local root, identity = projects.normalize_root(
        project.normalized_project_root, context.filesystem)
    assert(root == project.normalized_project_root and
        identity == project.normalized_identity,
        'owning project root no longer matches registration')
    validation.selection(run.selection)
    local path, path_identity = validation.normalize_result_path(project,
        context.filesystem)
    assert(path == run.result_path and path_identity == run.result_path_identity,
        'queued result path no longer matches registration')
    if context.validate_activation then
        local valid, reason = context.validate_activation(project, run)
        assert(valid == true, reason or
            'activation validator rejected the queued run')
    end
end

---Activates the FIFO head when the executor is idle and healthy.
function M.activate_next(registry, context)
    if registry.active_run_id then
        local active = assert(registry.runs[registry.active_run_id],
            'active executor references an unknown run')
        assert(not active.terminal and ACTIVE[active.state],
            'active executor references a non-executable run')
        return {activated=false, kind=FailureKind.EXECUTOR_BUSY,
            identity=validation.public_identity(active), run=active}
    end
    if registry.quarantine.active then return {activated=false,
        kind=FailureKind.EXECUTOR_QUARANTINED,
        reason=registry.quarantine.reason} end
    local run_id = registry.queue[1]
    if not run_id then return {activated=false} end
    local run = assert(registry.runs[run_id],
        'scheduler queue references an unknown run')
    assert(run.state == RunState.QUEUED and not run.terminal,
        'scheduler queue head is not queued')
    local valid, reason = pcall(revalidate, registry, run, context)
    local timestamp_ms = validation.current_time(context)
    if not valid then
        reason = tostring(reason):gsub('^.-:%d+: ', '')
        transitions.reject_activation(registry, run, reason, timestamp_ms)
        return {activated=false, kind=FailureKind.ACTIVATION_INVALID,
            reason=reason, identity=validation.public_identity(run), run=run}
    end
    transitions.activate(registry, run, timestamp_ms)
    return {activated=true, identity=validation.public_identity(run), run=run}
end

---Cancels one capability-owned queued run.
function M.cancel(registry, request, context)
    local run = validation.authorize_owner(registry, request, 'cancel')
    assert(type(request.reason) == 'string' and request.reason ~= '' and
        #request.reason <= 1024,
        'cancel reason must be a nonempty bounded string')
    if run.state ~= RunState.QUEUED or run.terminal then
        validation.reject('invalid_run_state',
            'Only a queued run can be cancelled.', {
                operation='cancel', run_id=run.run_id,
                generation=run.generation, state=run.state,
            })
    end
    return transitions.cancel_queued(registry, run, request.reason,
        run.owner_kind, validation.current_time(context))
end

---Cancels one queued run through operator authority.
function M.operator_cancel(registry, request, context)
    local run = validation.exact_run(registry, request, 'operator cancel')
    if run.state ~= RunState.QUEUED or run.terminal then
        validation.reject('invalid_run_state',
            'Only a queued run can be force-cancelled.', {
                operation='operator cancel', run_id=run.run_id,
                generation=run.generation, state=run.state,
            })
    end
    assert(type(request.reason) == 'string' and request.reason ~= '' and
        #request.reason <= 1024,
        'operator cancel reason must be a nonempty bounded string')
    local authority = validation.authorize_operator(context, request,
        'cancel', run, {
            request='operator cancel',
            authority='operator cancel authority',
        })
    local timestamp_ms = validation.current_time(context)
    transitions.operator_diagnostic(run, 'operator_cancel', request.reason,
        authority, timestamp_ms)
    return transitions.cancel_queued(registry, run, request.reason,
        'authorized operator', timestamp_ms)
end

---Cancels every expired external queue lease.
function M.expire_due_queue(registry, context)
    local timestamp_ms = validation.current_time(context)
    local expired, index = {}, 1
    while index <= #registry.queue do
        local run = assert(registry.runs[registry.queue[index]],
            'scheduler queue references an unknown run')
        local lease = run.queue_lease
        if run.owner_kind == OwnerKind.EXTERNAL and lease.active and
                timestamp_ms >= lease.expires_at_ms then
            transitions.mark_queue_expired(run)
            local reason = ('queue lease expired after %d ms'):format(
                lease.timeout_ms)
            table.insert(expired, transitions.cancel_queued(registry, run,
                reason, run.owner_kind, timestamp_ms))
        else index = index + 1 end
    end
    return expired
end

return M
