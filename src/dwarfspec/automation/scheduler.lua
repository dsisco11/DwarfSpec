-- Global FIFO admission and executor ownership for the automation service.

local events = require('dwarfspec.automation.events')
local EventType = require('dwarfspec.automation.event_types')
local OwnerKind = require('dwarfspec.automation.owner_kinds')
local projects = require('dwarfspec.automation.projects')
local ResultPolicy = require('dwarfspec.automation.result_policies')
local RunState = require('dwarfspec.automation.run_states')
local SchedulerFailureKind =
    require('dwarfspec.automation.scheduler_failure_kinds')

local M = {
    failure_kinds=SchedulerFailureKind,
}

local SUBMISSION_FIELDS = {
    selection=true,
    request_key=true,
    owner_kind=true,
    queue_lease_ms=true,
    execution_lease_ms=true,
    lease_check_frames=true,
}

local TERMINAL_STATES = {
    [RunState.PASSED]=true,
    [RunState.FAILED]=true,
    [RunState.ABORTED]=true,
    [RunState.CANCELLED]=true,
}

local ACTIVE_STATES = {
    [RunState.STARTING]=true,
    [RunState.RUNNING]=true,
    [RunState.CLEANING]=true,
}

---Returns an empty Busted result-count record.
---@return table
local function empty_counts()
    return {successes=0, failures=0, errors=0, pending=0}
end

---Returns one validated monotonic timestamp.
---@param context table
---@return number
local function current_time(context)
    local value = context.now_ms()
    assert(type(value) == 'number' and value >= 0,
        'scheduler clock returned an invalid timestamp')
    return value
end

---Validates one deterministic selection and returns a detached copy.
---@param selection table
---@return table
local function validate_selection(selection)
    assert(type(selection) == 'table',
        'run selection must be a table')
    assert(type(selection.identities) == 'table',
        'run selection identities must be a table')
    local previous
    for index, identity in ipairs(selection.identities) do
        assert(type(identity) == 'string' and identity ~= '',
            'run selection has invalid identity at ' .. index)
        assert(previous == nil or previous < identity,
            'run selection identities must be sorted and unique')
        previous = identity
    end
    for key in pairs(selection.identities) do
        assert(type(key) == 'number' and key >= 1 and key % 1 == 0 and
            key <= #selection.identities,
            'run selection identities must be a dense array')
    end
    return events.copy_json(selection, 'run selection')
end

---Validates one bounded optional caller request key.
---@param request_key any
---@return string|nil
local function validate_request_key(request_key)
    if request_key == nil then return nil end
    assert(type(request_key) == 'string' and #request_key >= 16 and
        #request_key <= 256,
        'run request key must contain between 16 and 256 bytes')
    return request_key
end

---Validates one owner kind safe for public event payloads.
---@param owner_kind any
---@return string
local function validate_owner_kind(owner_kind)
    owner_kind = owner_kind or OwnerKind.EXTERNAL
    assert(owner_kind == OwnerKind.EXTERNAL or
        owner_kind == OwnerKind.IN_PROCESS,
        'run owner kind must be a supported OwnerKind')
    return owner_kind
end

---Validates one positive lease duration in milliseconds.
---@param value any
---@param name string
---@return integer
local function validate_lease_duration(value, name)
    value = value or 5000
    assert(type(value) == 'number' and value >= 1 and
        value <= 86400000 and value % 1 == 0,
        name .. ' must be an integer between 1 and 86400000 milliseconds')
    return value
end

---Validates one positive frame interval for live lease checks.
---@param value any
---@return integer
local function validate_lease_check_frames(value)
    value = value or 30
    assert(type(value) == 'number' and value >= 1 and
        value <= 1000000 and value % 1 == 0,
        'lease check interval must be a positive bounded integer')
    return value
end

---Returns whether two detached JSON-safe values are structurally equal.
---@param left any
---@param right any
---@return boolean
local function json_equal(left, right)
    if type(left) ~= type(right) then return false end
    if type(left) ~= 'table' then return left == right end
    for key, value in pairs(left) do
        if not json_equal(value, right[key]) then return false end
    end
    for key in pairs(right) do
        if left[key] == nil then return false end
    end
    return true
end

---Returns whether a retry matches the request originally bound to its key.
---@param run table
---@param normalized table
---@return boolean
local function matches_request_key(run, normalized)
    return run.owner_kind == normalized.owner_kind and
        run.queue_lease.timeout_ms == normalized.queue_lease_ms and
        run.execution_lease.timeout_ms == normalized.execution_lease_ms and
        run.lease_check_frames == normalized.lease_check_frames and
        run.result_path_identity == normalized.result_path_identity and
        run.result_policy == normalized.project.result_policy and
        json_equal(run.selection, normalized.selection)
end

---Returns one generated unique run identifier.
---@param registry table
---@param generation integer
---@param context table
---@return string
local function allocate_run_id(registry, generation, context)
    local run_id = context.new_run_id(generation)
    assert(type(run_id) == 'string' and run_id ~= '',
        'run id generator returned an invalid identifier')
    assert(registry.runs[run_id] == nil,
        'run id generator returned an existing identifier')
    return run_id
end

---Returns one generated unique owner capability.
---@param registry table
---@param context table
---@return string
local function allocate_owner_capability(registry, context, run_id, generation)
    for _ = 1, 128 do
        local capability = context.new_owner_capability(run_id, generation)
        assert(type(capability) == 'string' and #capability >= 32 and
            #capability <= 512,
            'owner capability generator returned an invalid capability')
        local available = true
        for _, run in pairs(registry.runs) do
            if run.owner_capability == capability then
                available = false
                break
            end
        end
        if available then return capability end
    end
    error('owner capability generator repeatedly returned existing values')
end

local validate_run_identity

---Returns one exact capability-authorized run without changing it.
---@param registry table
---@param request table
---@param operation string
---@return table
local function authorize_owner(registry, request, operation)
    assert(type(request) == 'table',
        operation .. ' request must be a table')
    assert(request.service_instance_id == registry.service_instance_id,
        operation .. ' service identity does not match')
    assert(type(request.project_id) == 'string' and
        request.project_id ~= '',
        operation .. ' project id must be a nonempty string')
    assert(type(request.run_id) == 'string' and request.run_id ~= '',
        operation .. ' run id must be a nonempty string')
    local run = assert(registry.runs[request.run_id],
        'automation run was not found: ' .. tostring(request.run_id))
    assert(run.project_id == request.project_id,
        operation .. ' project identity does not match run')
    assert(run.generation == request.generation,
        operation .. ' generation does not match run')
    assert(type(request.owner_capability) == 'string' and
        request.owner_capability ~= '',
        operation .. ' owner capability must be a nonempty string')
    assert(run.owner_capability == request.owner_capability,
        operation .. ' owner capability does not match run')
    validate_run_identity(registry, run)
    return run
end

---Returns one run identity safe to expose without its owner capability.
---@param run table
---@return table
local function public_identity(run)
    return {
        service_instance_id=run.service_instance_id,
        project_id=run.project_id,
        run_id=run.run_id,
        generation=run.generation,
    }
end

---Validates one run's immutable service and project ownership identity.
---@param registry table
---@param run table
validate_run_identity = function(registry, run)
    assert(run.service_instance_id == registry.service_instance_id,
        'automation run belongs to a different service instance')
    local project = assert(registry.projects[run.project_id],
        'automation run belongs to an unregistered project')
    assert(project.outstanding_run_id == run.run_id,
        'automation project does not own the requested run')
    assert(type(run.generation) == 'number' and run.generation > 0 and
        run.generation % 1 == 0,
        'automation run has an invalid generation')
end

---Returns one exact run identity without authorizing an owner mutation.
---@param registry table
---@param request table
---@param operation string
---@return table
local function exact_run(registry, request, operation)
    assert(type(request) == 'table',
        operation .. ' request must be a table')
    assert(request.service_instance_id == registry.service_instance_id,
        operation .. ' service identity does not match')
    local run = assert(registry.runs[request.run_id],
        'automation run was not found: ' .. tostring(request.run_id))
    assert(run.project_id == request.project_id,
        operation .. ' project identity does not match run')
    assert(run.generation == request.generation,
        operation .. ' generation does not match run')
    validate_run_identity(registry, run)
    return run
end

---Returns a classified scheduler rejection for one existing run.
---@param kind DwarfSpecSchedulerFailureKind
---@param run table
---@param reason string
---@return table
local function rejected(kind, run, reason)
    return {
        accepted=false,
        kind=kind,
        reason=reason,
        identity=public_identity(run),
        run=run,
    }
end

---Returns whether one run still owns project and result-path admission.
---@param run table
---@return boolean
local function is_outstanding(run)
    return type(run) == 'table' and run.acknowledged ~= true and
        run.discarded ~= true
end

---Finds an outstanding run that reserves one canonical result path.
---@param registry table
---@param result_path_identity string|nil
---@return table|nil
local function find_result_path_owner(registry, result_path_identity)
    if result_path_identity == nil then return nil end
    for _, run in pairs(registry.runs) do
        if is_outstanding(run) and
                run.result_path_identity == result_path_identity then
            return run
        end
    end
    return nil
end

---Returns the normalized result path owned by one project policy.
---@param project table
---@param filesystem table|nil
---@return string|nil, string|nil
local function normalize_result_path(project, filesystem)
    if project.result_policy == ResultPolicy.NONE then return nil, nil end
    assert(project.result_policy == ResultPolicy.FILE,
        'registered project has unsupported result policy')
    return projects.normalize_file_path(project.result_path,
        project.normalized_project_root, filesystem)
end

---Validates a submission without changing service-owned state.
---@param registry table
---@param project_id string
---@param request table
---@param context table
---@return table
local function validate_submission(registry, project_id, request, context)
    assert(type(project_id) == 'string' and project_id ~= '',
        'submission project id must be a nonempty string')
    assert(type(request) == 'table',
        'run submission request must be a table')
    events.copy_json(request, 'run submission request')
    for field in pairs(request) do
        assert(SUBMISSION_FIELDS[field] == true,
            'run submission request has unsupported field: ' ..
                tostring(field))
    end
    local project = registry.projects[project_id]
    assert(type(project) == 'table',
        'registered project was not found: ' .. project_id)
    assert(project.client_compatibility.protocol ==
        registry.protocol_version,
        'registered project protocol is no longer compatible')
    assert(project.client_compatibility.package_version ==
        registry.package_version,
        'registered project package version is no longer compatible')
    local selection = validate_selection(request.selection)
    local request_key = validate_request_key(request.request_key)
    local owner_kind = validate_owner_kind(request.owner_kind)
    local queue_lease_ms = validate_lease_duration(
        request.queue_lease_ms, 'queue lease duration')
    local execution_lease_ms = validate_lease_duration(
        request.execution_lease_ms, 'execution lease duration')
    local lease_check_frames = validate_lease_check_frames(
        request.lease_check_frames)
    local result_path, result_path_identity = normalize_result_path(
        project, context.filesystem)
    return {
        project=project,
        selection=selection,
        request_key=request_key,
        owner_kind=owner_kind,
        queue_lease_ms=queue_lease_ms,
        execution_lease_ms=execution_lease_ms,
        lease_check_frames=lease_check_frames,
        result_path=result_path,
        result_path_identity=result_path_identity,
    }
end

---Admits one run to the global FIFO or returns a stable classified conflict.
---All validation and record construction complete before registry mutation.
---@param registry table
---@param project_id string
---@param request table
---@param context table
---@return table
function M.submit(registry, project_id, request, context)
    local normalized = validate_submission(registry, project_id, request,
        context)
    local project = normalized.project
    if normalized.request_key ~= nil then
        local request_keys = project.request_keys or {}
        local prior_id = request_keys[normalized.request_key]
        if prior_id ~= nil then
            local prior = assert(registry.runs[prior_id],
                'project request key references an unknown run')
            if not matches_request_key(prior, normalized) then
                return rejected(SchedulerFailureKind.REQUEST_KEY_CONFLICT,
                    prior,
                    'request key is already bound to a different request')
            end
            return {
                accepted=true,
                reused=true,
                owner_capability=prior.owner_capability,
                identity=public_identity(prior),
                run=prior,
            }
        end
    end

    if project.outstanding_run_id ~= nil then
        local outstanding = assert(
            registry.runs[project.outstanding_run_id],
            'project outstanding run identity is invalid')
        return rejected(SchedulerFailureKind.PROJECT_BUSY, outstanding,
            'project already owns an outstanding run')
    end

    local path_owner = find_result_path_owner(registry,
        normalized.result_path_identity)
    if path_owner ~= nil then
        return rejected(SchedulerFailureKind.RESULT_PATH_BUSY, path_owner,
            'result path is owned by another outstanding run')
    end

    local admitted_at_ms = current_time(context)
    local generation = registry.generation + 1
    local run_id = allocate_run_id(registry, generation, context)
    local owner_capability = allocate_owner_capability(
        registry, context, run_id, generation)
    local queue_lease = {
        active=normalized.owner_kind == OwnerKind.EXTERNAL,
        timeout_ms=normalized.queue_lease_ms,
    }
    if queue_lease.active then
        queue_lease.renewed_at_ms = admitted_at_ms
        queue_lease.expires_at_ms =
            admitted_at_ms + normalized.queue_lease_ms
    else
        queue_lease.service_owned = true
    end
    local run = {
        service_instance_id=registry.service_instance_id,
        project_id=project_id,
        run_id=run_id,
        generation=generation,
        state=RunState.QUEUED,
        terminal=false,
        submitted_at_ms=admitted_at_ms,
        activated_at_ms=nil,
        finished_at_ms=nil,
        selection=normalized.selection,
        request_key=normalized.request_key,
        owner_kind=normalized.owner_kind,
        owner_capability=owner_capability,
        lease_check_frames=normalized.lease_check_frames,
        result_policy=project.result_policy,
        result_path=normalized.result_path,
        result_path_identity=normalized.result_path_identity,
        queue_lease=queue_lease,
        execution_lease={
            active=false,
            timeout_ms=normalized.execution_lease_ms,
            service_owned=normalized.owner_kind == OwnerKind.IN_PROCESS,
        },
        cleanup_confirmed=false,
        mount_cleanup_verified=false,
        counts=empty_counts(),
        totals=empty_counts(),
        failures={},
        event_journal=events.new_journal({
            service_instance_id=registry.service_instance_id,
            project_id=project_id,
            run_id=run_id,
            generation=generation,
            admitted_at_ms=admitted_at_ms,
        }),
    }
    events.publish(run.event_journal, EventType.RUN_QUEUED, {
        selection=normalized.selection,
        queue_admitted_ms=admitted_at_ms,
        owner_kind=normalized.owner_kind,
    }, admitted_at_ms)
    if registry.quarantine.active then
        events.publish(run.event_journal, EventType.SCHEDULER_BLOCKED, {
            reason=registry.quarantine.reason,
        }, admitted_at_ms)
    end

    registry.generation = generation
    registry.runs[run_id] = run
    table.insert(registry.queue, run_id)
    project.outstanding_run_id = run_id
    project.request_keys = project.request_keys or {}
    if normalized.request_key ~= nil then
        project.request_keys[normalized.request_key] = run_id
    end
    return {
        accepted=true,
        reused=false,
        owner_capability=owner_capability,
        identity=public_identity(run),
        run=run,
    }
end

---Validates that a queued run still belongs to a compatible project.
---@param registry table
---@param run table
---@param context table
local function revalidate_activation(registry, run, context)
    local project = registry.projects[run.project_id]
    assert(type(project) == 'table',
        'owning project is no longer registered')
    assert(project.outstanding_run_id == run.run_id,
        'owning project no longer references the queued run')
    assert(project.client_compatibility.protocol ==
        registry.protocol_version,
        'owning project protocol is no longer compatible')
    assert(project.client_compatibility.package_version ==
        registry.package_version,
        'owning project package version is no longer compatible')
    local normalized_root, root_identity = projects.normalize_root(
        project.normalized_project_root, context.filesystem)
    assert(normalized_root == project.normalized_project_root and
        root_identity == project.normalized_identity,
        'owning project root no longer matches registration')
    validate_selection(run.selection)
    local result_path, result_identity = normalize_result_path(project,
        context.filesystem)
    assert(result_path == run.result_path and
        result_identity == run.result_path_identity,
        'queued result path no longer matches registration')
    if context.validate_activation ~= nil then
        local valid, reason = context.validate_activation(project, run)
        assert(valid == true, reason or
            'activation validator rejected the queued run')
    end
end

---Terminates one pre-execution run after activation validation fails.
---@param registry table
---@param run table
---@param reason string
---@param timestamp_ms number
local function reject_activation(registry, run, reason, timestamp_ms)
    table.remove(registry.queue, 1)
    run.state = RunState.FAILED
    run.terminal = true
    run.finished_at_ms = timestamp_ms
    run.queue_lease.active = false
    run.cleanup_confirmed = true
    run.cleanup_reason = 'native execution was not started'
    events.publish(run.event_journal, EventType.SCHEDULER_BLOCKED, {
        reason=reason,
    }, timestamp_ms)
    events.publish(run.event_journal, EventType.RUN_FINISHED, {
        terminal_state=RunState.FAILED,
        totals=run.totals,
        cleanup_required=false,
        cleanup_confirmed=true,
    }, timestamp_ms)
    registry.latest_terminal_results[run.project_id] = run.run_id
end

---Activates the FIFO head when the executor is idle and healthy.
---@param registry table
---@param context table
---@return table
function M.activate_next(registry, context)
    if registry.active_run_id ~= nil then
        local active = assert(registry.runs[registry.active_run_id],
            'active executor references an unknown run')
        assert(not active.terminal and ACTIVE_STATES[active.state] == true,
            'active executor references a non-executable run')
        return {
            activated=false,
            kind=SchedulerFailureKind.EXECUTOR_BUSY,
            identity=public_identity(active),
            run=active,
        }
    end
    if registry.quarantine.active then
        return {
            activated=false,
            kind=SchedulerFailureKind.EXECUTOR_QUARANTINED,
            reason=registry.quarantine.reason,
        }
    end
    local run_id = registry.queue[1]
    if run_id == nil then return {activated=false} end
    local run = assert(registry.runs[run_id],
        'scheduler queue references an unknown run')
    assert(run.state == RunState.QUEUED and not run.terminal,
        'scheduler queue head is not queued')

    local valid, reason = pcall(revalidate_activation, registry, run, context)
    local activated_at_ms = current_time(context)
    if not valid then
        reason = tostring(reason):gsub('^.-:%d+: ', '')
        reject_activation(registry, run, reason, activated_at_ms)
        return {
            activated=false,
            kind=SchedulerFailureKind.ACTIVATION_INVALID,
            reason=reason,
            identity=public_identity(run),
            run=run,
        }
    end

    table.remove(registry.queue, 1)
    run.state = RunState.STARTING
    run.activated_at_ms = activated_at_ms
    run.queue_wait_ms = activated_at_ms - run.submitted_at_ms
    run.queue_lease.active = false
    run.execution_lease.active = true
    run.execution_lease.renewed_at_ms = activated_at_ms
    run.execution_lease.expires_at_ms =
        activated_at_ms + run.execution_lease.timeout_ms
    run.execution_lease.expiring = nil
    registry.active_run_id = run_id
    events.publish(run.event_journal, EventType.RUN_ACTIVATED, {
        queue_wait_ms=run.queue_wait_ms,
    }, activated_at_ms)
    return {
        activated=true,
        identity=public_identity(run),
        run=run,
    }
end

---Moves the active generation from starting to running.
---@param registry table
---@param run_id string
---@param generation integer
---@param payload table
---@param context table
---@return table
function M.start_active(registry, run_id, generation, payload, context)
    assert(registry.active_run_id == run_id,
        'active executor identity does not match start')
    local run = assert(registry.runs[run_id],
        'active executor references an unknown run')
    validate_run_identity(registry, run)
    assert(run.generation == generation,
        'active executor generation does not match start')
    assert(run.state == RunState.STARTING and not run.terminal,
        'active executor run is not starting')
    events.validate_payload(EventType.RUN_STARTED, payload)
    local timestamp_ms = current_time(context)
    run.state = RunState.RUNNING
    run.started_at_ms = timestamp_ms
    events.publish(run.event_journal, EventType.RUN_STARTED, payload,
        timestamp_ms)
    return run
end

---Moves the active generation into cleanup and publishes its boundary event.
---@param registry table
---@param run_id string
---@param generation integer
---@param reason string
---@param pending_action_count integer
---@param context table
---@return table
function M.begin_cleanup(registry, run_id, generation, reason,
        pending_action_count, context)
    assert(registry.active_run_id == run_id,
        'active executor identity does not match cleanup')
    local run = assert(registry.runs[run_id],
        'active executor references an unknown run')
    validate_run_identity(registry, run)
    assert(run.generation == generation,
        'active executor generation does not match cleanup')
    assert((run.state == RunState.STARTING or
        run.state == RunState.RUNNING) and not run.terminal,
        'active executor run cannot enter cleanup from its current state')
    local payload = {
        reason=reason,
        pending_action_count=pending_action_count,
    }
    events.validate_payload(EventType.CLEANUP_STARTED, payload)
    local timestamp_ms = current_time(context)
    run.state = RunState.CLEANING
    run.execution_lease.active = false
    run.execution_lease.expiring = nil
    events.publish(run.event_journal, EventType.CLEANUP_STARTED, payload,
        timestamp_ms)
    return run
end

---Publishes one generation-guarded event for the active executor.
---@param registry table
---@param run_id string
---@param generation integer
---@param event_type DwarfSpecEventType
---@param payload table
---@param context table
---@return table
function M.publish_active_event(registry, run_id, generation, event_type,
        payload, context)
    assert(registry.active_run_id == run_id,
        'event publisher no longer owns the active executor')
    local run = assert(registry.runs[run_id],
        'event publisher references an unknown run')
    validate_run_identity(registry, run)
    assert(run.generation == generation,
        'event publisher generation does not match active run')
    assert(ACTIVE_STATES[run.state] == true and not run.terminal,
        'event publisher run is not active')
    return events.publish(run.event_journal, event_type, payload,
        current_time(context))
end

---Applies one queued terminal cancellation without invoking native cleanup.
---@param registry table
---@param run table
---@param reason string
---@param owner string
---@param cancelled_at_ms number
---@return table
local function cancel_queued(registry, run, reason, owner, cancelled_at_ms)
    local queue_index
    for index, queued_id in ipairs(registry.queue) do
        if queued_id == run.run_id then queue_index = index break end
    end
    assert(queue_index ~= nil, 'queued run is missing from scheduler FIFO')
    table.remove(registry.queue, queue_index)
    run.state = RunState.CANCELLED
    run.terminal = true
    run.finished_at_ms = cancelled_at_ms
    run.queue_lease.active = false
    run.cleanup_confirmed = true
    run.cleanup_reason = 'native execution was not started'
    run.terminal_reason = reason
    events.publish(run.event_journal, EventType.RUN_CANCELLED, {
        reason=reason,
        owner=owner,
    }, cancelled_at_ms)
    events.publish(run.event_journal, EventType.RUN_FINISHED, {
        terminal_state=RunState.CANCELLED,
        totals=run.totals,
        cleanup_required=false,
        cleanup_confirmed=true,
    }, cancelled_at_ms)
    registry.latest_terminal_results[run.project_id] = run.run_id
    return {cancelled=true, identity=public_identity(run), run=run}
end

---Cancels one capability-owned queued run without native cleanup.
---@param registry table
---@param request table
---@param context table
---@return table
function M.cancel(registry, request, context)
    local run = authorize_owner(registry, request, 'cancel')
    assert(type(request.reason) == 'string' and request.reason ~= '' and
        #request.reason <= 1024,
        'cancel reason must be a nonempty bounded string')
    assert(run.state == RunState.QUEUED and not run.terminal,
        'only a queued run can be cancelled')
    return cancel_queued(registry, run, request.reason, run.owner_kind,
        current_time(context))
end

---Cancels one queued run through authorized operator recovery.
---@param registry table
---@param request table
---@param context table
---@return table
function M.operator_cancel(registry, request, context)
    local run = exact_run(registry, request, 'operator cancel')
    assert(run.state == RunState.QUEUED and not run.terminal,
        'only a queued run can be force-cancelled')
    assert(type(request.reason) == 'string' and request.reason ~= '' and
        #request.reason <= 1024,
        'operator cancel reason must be a nonempty bounded string')
    assert(type(request.authority) == 'table',
        'operator cancel requires operator authority')
    events.copy_json(request.authority, 'operator cancel authority')
    assert(type(context.authorize_operator) == 'function',
        'operator cancel requires an authority verifier')
    local authorized, authority_label = context.authorize_operator(
        request.authority, 'cancel', run)
    assert(authorized == true, authority_label or
        'operator cancel authority was rejected')
    local timestamp_ms = current_time(context)
    events.publish(run.event_journal, EventType.DIAGNOSTIC_RECORDED, {
        kind='operator_cancel',
        content={
            reason=request.reason,
            authority=tostring(authority_label or 'authorized operator'),
        },
    }, timestamp_ms)
    return cancel_queued(registry, run, request.reason,
        'authorized operator', timestamp_ms)
end

---Cancels every expired external queue lease without native cleanup.
---@param registry table
---@param context table
---@return table[]
function M.expire_due_queue(registry, context)
    local timestamp_ms = current_time(context)
    local expired = {}
    local index = 1
    while index <= #registry.queue do
        local run = assert(registry.runs[registry.queue[index]],
            'scheduler queue references an unknown run')
        local lease = run.queue_lease
        if run.owner_kind == OwnerKind.EXTERNAL and lease.active and
                timestamp_ms >= lease.expires_at_ms then
            lease.expired = true
            local reason = ('queue lease expired after %d ms')
                :format(lease.timeout_ms)
            local outcome = cancel_queued(registry, run, reason,
                run.owner_kind, timestamp_ms)
            table.insert(expired, outcome)
        else
            index = index + 1
        end
    end
    return expired
end

---Renews the applicable external queue or execution lease.
---@param registry table
---@param request table
---@param context table
---@return table
function M.renew(registry, request, context)
    local run = authorize_owner(registry, request, 'lease renewal')
    assert(run.owner_kind == OwnerKind.EXTERNAL,
        'only an external owner renews a caller lease')
    assert(not run.terminal,
        'a terminal run does not own a renewable lease')
    local lease
    if run.state == RunState.QUEUED then
        lease = run.queue_lease
    elseif ACTIVE_STATES[run.state] then
        lease = run.execution_lease
    else
        error('run state does not own a renewable lease')
    end
    assert(lease.active and not lease.expiring,
        'run lease is not active')
    local renewed_at_ms = current_time(context)
    assert(renewed_at_ms < lease.expires_at_ms,
        'run lease has already expired')
    lease.renewed_at_ms = renewed_at_ms
    lease.expires_at_ms = renewed_at_ms + lease.timeout_ms
    return run
end

---Renews one service-owned in-process execution heartbeat.
---@param registry table
---@param request table
---@param context table
---@return table
function M.heartbeat(registry, request, context)
    assert(type(request) == 'table',
        'service heartbeat request must be a table')
    assert(request.service_instance_id == registry.service_instance_id,
        'service heartbeat service identity does not match')
    local run = assert(registry.runs[request.run_id],
        'automation run was not found: ' .. tostring(request.run_id))
    assert(run.project_id == request.project_id,
        'service heartbeat project identity does not match run')
    assert(run.generation == request.generation,
        'service heartbeat generation does not match run')
    validate_run_identity(registry, run)
    assert(run.owner_kind == OwnerKind.IN_PROCESS,
        'service heartbeat requires an in-process-owned run')
    assert(ACTIVE_STATES[run.state] and not run.terminal,
        'service heartbeat requires an active run')
    local lease = run.execution_lease
    assert(lease.active and lease.service_owned,
        'in-process execution lease is not active')
    local renewed_at_ms = current_time(context)
    lease.renewed_at_ms = renewed_at_ms
    lease.expires_at_ms = renewed_at_ms + lease.timeout_ms
    return run
end

---Claims one expired active external lease for emergency abort.
---@param registry table
---@param context table
---@return table|nil
function M.claim_expired_active(registry, context)
    if registry.active_run_id == nil then return nil end
    local run = assert(registry.runs[registry.active_run_id],
        'active executor references an unknown run')
    local lease = run.execution_lease
    if run.owner_kind ~= OwnerKind.EXTERNAL or not lease.active or
            current_time(context) < lease.expires_at_ms then
        return nil
    end
    lease.active = false
    lease.expired = true
    lease.expiring = true
    return run
end

---Authorizes a capability-owned active run for normal abort.
---@param registry table
---@param request table
---@return table
function M.authorize_abort(registry, request)
    local run = authorize_owner(registry, request, 'abort')
    assert(type(request.reason) == 'string' and request.reason ~= '' and
        #request.reason <= 1024,
        'abort reason must be a nonempty bounded string')
    assert(registry.active_run_id == run.run_id and
        ACTIVE_STATES[run.state] and not run.terminal,
        'only the active run can be aborted')
    return run
end

---Finishes and releases the active executor generation.
---This scheduler seam is called by the service-owned host implemented later.
---@param registry table
---@param run_id string
---@param generation integer
---@param terminal_state DwarfSpecRunState
---@param cleanup_confirmed boolean
---@param reason string|nil
---@param context table
---@return table
function M.finish_active(registry, run_id, generation, terminal_state,
        cleanup_confirmed, reason, context)
    assert(TERMINAL_STATES[terminal_state] == true and
        terminal_state ~= RunState.CANCELLED,
        'active run terminal state must be passed, failed, or aborted')
    assert(type(cleanup_confirmed) == 'boolean',
        'active run cleanup confirmation must be boolean')
    if reason ~= nil then
        assert(type(reason) == 'string' and reason ~= '' and #reason <= 1024,
            'active completion reason must be a nonempty bounded string')
    end
    assert(registry.active_run_id == run_id,
        'active executor identity does not match completion')
    local run = assert(registry.runs[run_id],
        'active executor references an unknown run')
    validate_run_identity(registry, run)
    assert(run.generation == generation,
        'active executor generation does not match completion')
    assert(not run.terminal and ACTIVE_STATES[run.state] == true,
        'active executor run is not in an executable state')
    local finished_at_ms = current_time(context)

    run.state = terminal_state
    run.terminal = true
    run.finished_at_ms = finished_at_ms
    run.execution_lease.active = false
    run.cleanup_confirmed = cleanup_confirmed
    run.cleanup_reason = reason
    events.publish(run.event_journal, EventType.RUN_FINISHED, {
        terminal_state=terminal_state,
        totals=run.totals,
        cleanup_required=true,
        cleanup_confirmed=cleanup_confirmed,
    }, finished_at_ms)
    registry.active_run_id = nil
    registry.latest_terminal_results[run.project_id] = run.run_id
    if not cleanup_confirmed then
        local quarantine_reason = reason or
            'active run cleanup was not confirmed'
        registry.quarantine = {
            active=true,
            reason=quarantine_reason,
            run_id=run_id,
            generation=generation,
        }
        for _, queued_id in ipairs(registry.queue) do
            local queued = registry.runs[queued_id]
            events.publish(queued.event_journal,
                EventType.SCHEDULER_BLOCKED, {
                    reason=quarantine_reason,
                }, finished_at_ms)
        end
    end
    return {finished=true, identity=public_identity(run), run=run}
end

---Clears executor quarantine after an authoritative clean-state verifier.
---@param registry table
---@param request table
---@param context table
---@return table
function M.recover_executor(registry, request, context)
    assert(registry.quarantine.active,
        'automation executor is not quarantined')
    assert(type(request) == 'table',
        'executor recovery request must be a table')
    assert(request.service_instance_id == registry.service_instance_id,
        'executor recovery service identity does not match')
    assert(request.run_id == registry.quarantine.run_id,
        'executor recovery run identity does not match quarantine')
    assert(request.generation == registry.quarantine.generation,
        'executor recovery generation does not match quarantine')
    assert(type(request.reason) == 'string' and request.reason ~= '' and
        #request.reason <= 1024,
        'executor recovery reason must be a nonempty bounded string')
    assert(type(request.proof) == 'table',
        'executor recovery requires a clean-state proof')
    events.copy_json(request.proof, 'executor recovery proof')
    assert(type(context.verify_clean_state) == 'function',
        'executor recovery requires an authoritative verifier')
    local verified, detail = context.verify_clean_state(request.proof)
    assert(verified == true,
        detail or 'executor clean-state proof was rejected')
    registry.quarantine = {active=false}
    return {recovered=true}
end

---Acknowledges one exact owner-retained terminal result after persistence.
---@param registry table
---@param request table
---@param context table
---@return table
function M.acknowledge(registry, request, context)
    local run = authorize_owner(registry, request, 'acknowledgement')
    assert(run.terminal and TERMINAL_STATES[run.state] == true,
        'only a terminal run can be acknowledged')
    assert(run.acknowledged ~= true and run.discarded ~= true,
        'terminal run has already been released')
    local persistence = request.persistence
    assert(type(persistence) == 'table' and
        persistence.succeeded == true,
        'acknowledgement requires successful persistence')
    assert(persistence.policy == run.result_policy,
        'acknowledgement persistence policy does not match run')
    if run.result_policy == ResultPolicy.FILE then
        assert(persistence.result_path == run.result_path,
            'acknowledgement result path does not match run')
    end
    run.acknowledged = true
    run.acknowledged_at_ms = current_time(context)
    registry.projects[run.project_id].outstanding_run_id = nil
    return run
end

---Releases one exact retained terminal result through operator authority.
---@param registry table
---@param request table
---@param context table
---@return table
function M.discard(registry, request, context)
    local run = exact_run(registry, request, 'discard')
    assert(run.terminal and TERMINAL_STATES[run.state] == true,
        'only a terminal run can be discarded')
    assert(run.acknowledged ~= true and run.discarded ~= true,
        'terminal run has already been released')
    assert(type(request.reason) == 'string' and request.reason ~= '' and
        #request.reason <= 1024,
        'discard reason must be a nonempty bounded string')
    assert(type(request.authority) == 'table',
        'discard requires operator authority')
    events.copy_json(request.authority, 'discard operator authority')
    assert(type(context.authorize_operator) == 'function',
        'discard requires an operator authority verifier')
    local authorized, authority_label = context.authorize_operator(
        request.authority, 'discard', run)
    assert(authorized == true, authority_label or
        'discard operator authority was rejected')
    local discarded_at_ms = current_time(context)
    events.publish(run.event_journal, EventType.DIAGNOSTIC_RECORDED, {
        kind='operator_discard',
        content={
            reason=request.reason,
            authority=tostring(authority_label or 'authorized operator'),
        },
    }, discarded_at_ms)
    run.discarded = true
    run.discarded_at_ms = discarded_at_ms
    run.discard_reason = request.reason
    registry.projects[run.project_id].outstanding_run_id = nil
    return run
end

---Authorizes an operator recovery abort without impersonating the owner.
---@param registry table
---@param request table
---@param context table
---@return table
function M.authorize_operator_abort(registry, request, context)
    local run = exact_run(registry, request, 'operator abort')
    assert(registry.active_run_id == run.run_id and
        ACTIVE_STATES[run.state] and not run.terminal,
        'only the active run can be force-aborted')
    assert(type(request.reason) == 'string' and request.reason ~= '' and
        #request.reason <= 1024,
        'operator abort reason must be a nonempty bounded string')
    assert(type(request.authority) == 'table',
        'operator abort requires operator authority')
    events.copy_json(request.authority, 'operator abort authority')
    assert(type(context.authorize_operator) == 'function',
        'operator abort requires an authority verifier')
    local authorized, authority_label = context.authorize_operator(
        request.authority, 'abort', run)
    assert(authorized == true, authority_label or
        'operator abort authority was rejected')
    events.publish(run.event_journal, EventType.DIAGNOSTIC_RECORDED, {
        kind='operator_abort',
        content={
            reason=request.reason,
            authority=tostring(authority_label or 'authorized operator'),
        },
    }, current_time(context))
    return run
end

return M
