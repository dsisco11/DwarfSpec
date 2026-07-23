-- Process-wide multi-project automation service runtime and public boundary.

local projects = require('dwarfspec.automation.projects')
local events = require('dwarfspec.automation.events')
local OwnerKind = require('dwarfspec.automation.owner_kinds')
local RunState = require('dwarfspec.automation.run_states')
local scheduler = require('dwarfspec.automation.scheduler')
local schemas = require('dwarfspec.automation.schemas')
local snapshots = require('dwarfspec.automation.snapshots')

local M = {
    protocol_version=2,
    schema='dwarfspec.service.v2',
}

---Returns the runtime namespace that owns the process-wide service registry.
---@param dependencies table|nil
---@return table
local function runtime_namespace(dependencies)
    local namespace = dependencies and dependencies.namespace or
        rawget(_G, 'dfhack')
    assert(type(namespace) == 'table',
        'automation service requires a runtime namespace')
    return namespace
end

---Returns the monotonic service timestamp in milliseconds.
---@param dependencies table|nil
---@return number
local function now_ms(dependencies)
    if dependencies and dependencies.now_ms then
        local value = dependencies.now_ms()
        assert(type(value) == 'number' and value >= 0,
            'automation service clock returned an invalid timestamp')
        return value
    end
    local dfhack_runtime = rawget(_G, 'dfhack')
    if dfhack_runtime and type(dfhack_runtime.getTickCount) == 'function' then
        return dfhack_runtime.getTickCount()
    end
    return math.floor(os.clock() * 1000)
end

---Returns one opaque service instance identifier.
---@param dependencies table|nil
---@return string
local function new_service_instance_id(dependencies)
    if dependencies and dependencies.new_service_instance_id then
        local value = dependencies.new_service_instance_id()
        assert(type(value) == 'string' and value ~= '',
            'service instance id generator returned an invalid identifier')
        return value
    end
    return ('service-%d-%08x'):format(
        math.floor(now_ms(dependencies)), math.random(0, 0x7fffffff))
end

---Returns the project filesystem dependency for canonicalization.
---@param dependencies table|nil
---@return table|nil
local function project_filesystem(dependencies)
    return dependencies and dependencies.filesystem or nil
end

---Returns one service-assigned run identifier.
---@param generation integer
---@param dependencies table|nil
---@return string
local function new_run_id(generation, dependencies)
    if dependencies and dependencies.new_run_id then
        return dependencies.new_run_id(generation)
    end
    return ('run-%d-%08x'):format(
        generation, math.random(0, 0x7fffffff))
end

---Returns one opaque high-entropy owner capability.
---@param dependencies table|nil
---@return string
local function new_owner_capability(dependencies, run_id, generation)
    if dependencies and dependencies.new_owner_capability then
        return dependencies.new_owner_capability(run_id, generation)
    end
    return ('owner-%08x-%08x-%08x-%08x'):format(
        math.random(0, 0x7fffffff),
        math.random(0, 0x7fffffff),
        math.random(0, 0x7fffffff),
        math.random(0, 0x7fffffff))
end

---Returns dependencies used by stateless scheduler mutations.
---@param dependencies table|nil
---@return table
local function scheduler_context(dependencies)
    return {
        filesystem=project_filesystem(dependencies),
        now_ms=function()
            return now_ms(dependencies)
        end,
        new_run_id=function(generation)
            return new_run_id(generation, dependencies)
        end,
        new_owner_capability=function(run_id, generation)
            return new_owner_capability(dependencies, run_id, generation)
        end,
        validate_activation=dependencies and
            dependencies.validate_activation or nil,
        verify_clean_state=dependencies and
            dependencies.verify_clean_state or nil,
        authorize_operator=dependencies and
            dependencies.authorize_operator or nil,
    }
end

---Validates a service bootstrap request without changing runtime state.
---@param request table
local function validate_bootstrap_request(request)
    assert(type(request) == 'table',
        'automation service bootstrap request must be a table')
    assert(request.protocol_version == M.protocol_version,
        ('incompatible automation service protocol: expected %d, found %s')
            :format(M.protocol_version, tostring(request.protocol_version)))
    assert(type(request.package_root) == 'string' and
        request.package_root ~= '',
        'automation service package root must be a nonempty string')
    assert(type(request.package_version) == 'string' and
        request.package_version ~= '',
        'automation service package version must be a nonempty string')
end

---Validates the process-wide registry shape owned by this service version.
---@param registry table
local function validate_registry(registry)
    assert(type(registry) == 'table' and registry.schema == M.schema,
        'runtime contains an incompatible automation registry')
    assert(registry.protocol_version == M.protocol_version,
        ('incompatible automation service protocol: expected %d, found %s')
            :format(M.protocol_version,
                tostring(registry.protocol_version)))
    for _, field in ipairs({
            'service_instance_id', 'package_root', 'package_version',
            'generation', 'next_project_sequence', 'projects', 'runs',
            'queue', 'quarantine', 'latest_terminal_results'}) do
        assert(registry[field] ~= nil,
            'automation service registry is missing field: ' .. field)
    end
end

---Returns the existing compatible service registry.
---@param dependencies table|nil
---@return table
local function require_registry(dependencies)
    local registry = runtime_namespace(dependencies).dwarfspec
    assert(registry ~= nil, 'automation service has not been bootstrapped')
    validate_registry(registry)
    return registry
end

---Returns the currently renewable lease for one nonterminal run.
---@param run table
---@return table|nil
local function current_lease(run)
    if run.state == RunState.QUEUED then return run.queue_lease end
    if run.state == RunState.STARTING or run.state == RunState.RUNNING then
        return run.execution_lease
    end
    return nil
end

---Cancels one service-owned lease timer without touching lease state.
---@param run table
---@param dependencies table|nil
local function cancel_lease_timer(run, dependencies)
    local timer_id = run.lease_timer_id
    run.lease_timer_id = nil
    run.lease_timer_generation = (run.lease_timer_generation or 0) + 1
    if timer_id ~= nil and dependencies and
            type(dependencies.cancel_lease_timer) == 'function' then
        dependencies.cancel_lease_timer(timer_id)
    end
end

local arm_lease_timer

---Handles one exact service-owned lease timer callback.
---@param run_id string
---@param generation integer
---@param timer_generation integer
---@param dependencies table
local function lease_timer_fired(run_id, generation, timer_generation,
        dependencies)
    local registry = require_registry(dependencies)
    local run = registry.runs[run_id]
    if run == nil or run.generation ~= generation or
            run.lease_timer_generation ~= timer_generation then
        return
    end
    run.lease_timer_id = nil
    local ok, failure = xpcall(function()
        if run.owner_kind == OwnerKind.IN_PROCESS and
                run.execution_lease.active then
            M.heartbeat({
                service_instance_id=registry.service_instance_id,
                project_id=run.project_id,
                run_id=run.run_id,
                generation=run.generation,
            }, dependencies)
            return
        end
        M.expire_leases(dependencies)
        if registry.runs[run_id] == run and not run.terminal then
            arm_lease_timer(registry, run, dependencies)
        end
    end, debug.traceback)
    if not ok then run.lease_timer_error = tostring(failure) end
end

---Arms the timer for one currently renewable queue or execution lease.
---@param registry table
---@param run table
---@param dependencies table|nil
arm_lease_timer = function(registry, run, dependencies)
    cancel_lease_timer(run, dependencies)
    local lease = current_lease(run)
    if lease == nil or not lease.active or not dependencies or
            type(dependencies.schedule_lease_timer) ~= 'function' then
        return
    end
    local timestamp_ms = now_ms(dependencies)
    local delay_ms
    if run.owner_kind == OwnerKind.IN_PROCESS then
        delay_ms = math.max(1, math.floor(lease.timeout_ms / 2))
    else
        delay_ms = math.max(1, lease.expires_at_ms - timestamp_ms)
    end
    local timer_generation = run.lease_timer_generation
    local timer_id = dependencies.schedule_lease_timer(
        run, delay_ms, function()
            lease_timer_fired(run.run_id, run.generation,
                timer_generation, dependencies)
        end)
    assert(timer_id ~= nil,
        'automation service lease timer was rejected')
    run.lease_timer_id = timer_id
end

---Counts keys in one service-owned record map.
---@param values table
---@return integer
local function count_keys(values)
    local count = 0
    for _ in pairs(values) do count = count + 1 end
    return count
end

---Returns a detached JSON-safe service summary.
---@param registry table
---@return table
local function service_summary(registry)
    local summary = events.copy_json({
        schema=registry.schema,
        protocol_version=registry.protocol_version,
        service_instance_id=registry.service_instance_id,
        package_root=registry.package_root,
        package_version=registry.package_version,
        generation=registry.generation,
        project_count=count_keys(registry.projects),
        run_count=count_keys(registry.runs),
        queue=registry.queue,
        active_run_id=registry.active_run_id,
        quarantine=registry.quarantine,
        latest_terminal_results=registry.latest_terminal_results,
    }, 'service summary')
    schemas.validate_service(summary)
    return summary
end

---Validates one project client's compatibility with the running service.
---@param registry table
---@param request table
local function validate_project_compatibility(registry, request)
    assert(type(request) == 'table',
        'project registration request must be a table')
    local compatibility = request.client_compatibility
    assert(type(compatibility) == 'table',
        'project client compatibility must be a table')
    assert(compatibility.protocol == registry.protocol_version,
        ('incompatible project protocol: expected %d, found %s')
            :format(registry.protocol_version,
                tostring(compatibility.protocol)))
    assert(compatibility.package_version == registry.package_version,
        ('incompatible project package version: expected %s, found %s')
            :format(registry.package_version,
                tostring(compatibility.package_version)))
end

---Bootstraps or validates the process-wide automation service.
---@param request table
---@param dependencies table|nil
---@return table
function M.bootstrap(request, dependencies)
    validate_bootstrap_request(request)
    local namespace = runtime_namespace(dependencies)
    local registry = namespace.dwarfspec
    if registry ~= nil then
        validate_registry(registry)
        assert(request.package_version == registry.package_version,
            ('incompatible automation package version: expected %s, found %s')
                :format(registry.package_version,
                    tostring(request.package_version)))
        return service_summary(registry)
    end

    local normalized_package_root = projects.normalize_root(
        request.package_root, project_filesystem(dependencies))
    local created = {
        schema=M.schema,
        protocol_version=M.protocol_version,
        service_instance_id=new_service_instance_id(dependencies),
        package_root=normalized_package_root,
        package_version=request.package_version,
        generation=0,
        next_project_sequence=1,
        projects={},
        runs={},
        queue={},
        active_run_id=nil,
        quarantine={active=false},
        latest_terminal_results={},
    }
    namespace.dwarfspec = created
    return service_summary(created)
end

---Registers or refreshes one compatible project session.
---@param request table
---@param dependencies table|nil
---@return table
function M.register_project(request, dependencies)
    local registry = require_registry(dependencies)
    validate_project_compatibility(registry, request)
    local next_sequence = registry.next_project_sequence

    ---Returns the current dependency-injected registration timestamp.
    ---@return number
    local function registration_time()
        return now_ms(dependencies)
    end

    ---Allocates one service-owned project identifier without mutating state.
    ---@return string
    local function allocate_project_id()
        local project_id
        repeat
            project_id = 'project-' .. tostring(next_sequence)
            next_sequence = next_sequence + 1
        until registry.projects[project_id] == nil
        return project_id
    end

    local updated, summary = projects.register(registry.projects, request, {
        filesystem=project_filesystem(dependencies),
        now_ms=registration_time,
        next_project_id=allocate_project_id,
    })
    registry.projects = updated
    registry.next_project_sequence = next_sequence
    return summary
end

---Unregisters one idle project session.
---@param project_id string
---@param dependencies table|nil
---@return table
function M.unregister_project(project_id, dependencies)
    local registry = require_registry(dependencies)
    local updated, removed = projects.unregister(
        registry.projects, project_id)
    registry.projects = updated
    return removed
end

---Returns one detached project summary by identifier.
---@param project_id string
---@param dependencies table|nil
---@return table|nil
function M.project(project_id, dependencies)
    local registry = require_registry(dependencies)
    return projects.lookup(registry.projects, project_id)
end

---Returns all detached project summaries in deterministic order.
---@param dependencies table|nil
---@return table[]
function M.projects(dependencies)
    local registry = require_registry(dependencies)
    return projects.list(registry.projects)
end

---Returns one detached JSON-safe service summary.
---@param dependencies table|nil
---@return table
function M.summary(dependencies)
    return service_summary(require_registry(dependencies))
end

---Returns one detached immutable run snapshot by identifier.
---@param run_id string
---@param dependencies table|nil
---@return table
function M.snapshot(run_id, dependencies)
    assert(type(run_id) == 'string' and run_id ~= '',
        'run id must be a nonempty string')
    local registry = require_registry(dependencies)
    local run = registry.runs[run_id]
    assert(type(run) == 'table',
        'automation run was not found: ' .. run_id)
    return snapshots.run(run, registry)
end

---Returns immutable run events after one stable cursor.
---@param run_id string
---@param after_sequence integer
---@param dependencies table|nil
---@return table
function M.events(run_id, after_sequence, dependencies)
    assert(type(run_id) == 'string' and run_id ~= '',
        'run id must be a nonempty string')
    local registry = require_registry(dependencies)
    local run = registry.runs[run_id]
    assert(type(run) == 'table',
        'automation run was not found: ' .. run_id)
    assert(type(run.event_journal) == 'table',
        'automation run does not own an event journal: ' .. run_id)
    return events.read(run.event_journal, after_sequence)
end

---Returns one detached immutable scheduler snapshot.
---@param dependencies table|nil
---@return table
function M.scheduler_snapshot(dependencies)
    return snapshots.scheduler(require_registry(dependencies))
end

---Admits one project run to the global scheduler FIFO.
---@param project_id string
---@param request table
---@param dependencies table|nil
---@return table
function M.submit(project_id, request, dependencies)
    local registry = require_registry(dependencies)
    local outcome = scheduler.submit(registry, project_id, request,
        scheduler_context(dependencies))
    if outcome.accepted and not outcome.reused then
        arm_lease_timer(registry, outcome.run, dependencies)
    end
    local response = {
        accepted=outcome.accepted,
        reused=outcome.reused,
        kind=outcome.kind,
        reason=outcome.reason,
        identity=outcome.identity,
        snapshot=snapshots.run(outcome.run, registry),
    }
    if outcome.accepted then
        response.owner_capability = outcome.owner_capability
    end
    return response
end

---Activates the current FIFO head when the executor is available.
---@param dependencies table|nil
---@return table
function M.activate_next(dependencies)
    local registry = require_registry(dependencies)
    M.expire_leases(dependencies)
    local outcome = scheduler.activate_next(registry,
        scheduler_context(dependencies))
    if outcome.activated then
        arm_lease_timer(registry, outcome.run, dependencies)
    end
    return {
        activated=outcome.activated,
        kind=outcome.kind,
        reason=outcome.reason,
        identity=outcome.identity,
        snapshot=outcome.run and snapshots.run(outcome.run, registry) or nil,
    }
end

---Moves the active generation from starting to running.
---@param run_id string
---@param generation integer
---@param payload table
---@param dependencies table|nil
---@return table
function M.start_active(run_id, generation, payload, dependencies)
    local registry = require_registry(dependencies)
    local run = scheduler.start_active(registry, run_id, generation,
        payload, scheduler_context(dependencies))
    return snapshots.run(run, registry)
end

---Moves the active generation into cleanup.
---@param run_id string
---@param generation integer
---@param reason string
---@param pending_action_count integer
---@param dependencies table|nil
---@return table
function M.begin_cleanup(run_id, generation, reason, pending_action_count,
        dependencies)
    local registry = require_registry(dependencies)
    local run = scheduler.begin_cleanup(registry, run_id, generation,
        reason, pending_action_count, scheduler_context(dependencies))
    cancel_lease_timer(run, dependencies)
    return snapshots.run(run, registry)
end

---Publishes one structured event for the exact active generation.
---@param run_id string
---@param generation integer
---@param event_type DwarfSpecEventType
---@param payload table
---@param dependencies table|nil
---@return table
function M.publish_active_event(run_id, generation, event_type, payload,
        dependencies)
    local registry = require_registry(dependencies)
    return scheduler.publish_active_event(registry, run_id, generation,
        event_type, payload, scheduler_context(dependencies))
end

---Renews the applicable exact capability-owned external lease.
---@param request table
---@param dependencies table|nil
---@return table
function M.renew(request, dependencies)
    local registry = require_registry(dependencies)
    local run = scheduler.renew(registry, request,
        scheduler_context(dependencies))
    arm_lease_timer(registry, run, dependencies)
    return snapshots.run(run, registry)
end

---Renews one service-owned in-process execution heartbeat.
---@param request table
---@param dependencies table|nil
---@return table
function M.heartbeat(request, dependencies)
    local registry = require_registry(dependencies)
    local run = scheduler.heartbeat(registry, request,
        scheduler_context(dependencies))
    arm_lease_timer(registry, run, dependencies)
    return snapshots.run(run, registry)
end

---Cancels one owned queued run without invoking native cleanup.
---@param request table
---@param dependencies table|nil
---@return table
function M.cancel(request, dependencies)
    local registry = require_registry(dependencies)
    local outcome = scheduler.cancel(registry, request,
        scheduler_context(dependencies))
    cancel_lease_timer(outcome.run, dependencies)
    return {
        cancelled=outcome.cancelled,
        identity=outcome.identity,
        snapshot=snapshots.run(outcome.run, registry),
    }
end

---Cancels one queued run through authorized operator recovery.
---@param request table
---@param dependencies table
---@return table
function M.operator_cancel(request, dependencies)
    local registry = require_registry(dependencies)
    local outcome = scheduler.operator_cancel(registry, request,
        scheduler_context(dependencies))
    cancel_lease_timer(outcome.run, dependencies)
    return {
        cancelled=outcome.cancelled,
        identity=outcome.identity,
        snapshot=snapshots.run(outcome.run, registry),
    }
end

---Aborts one exact capability-owned active run through native cleanup.
---@param request table
---@param dependencies table
---@return table
function M.abort(request, dependencies)
    local registry = require_registry(dependencies)
    local run = scheduler.authorize_abort(registry, request)
    assert(type(dependencies) == 'table' and
        type(dependencies.abort_active) == 'function',
        'active abort requires the service host cleanup boundary')
    dependencies.abort_active({
        service_instance_id=run.service_instance_id,
        project_id=run.project_id,
        run_id=run.run_id,
        generation=run.generation,
    }, request.reason)
    assert(run.terminal and run.state == RunState.ABORTED,
        'active abort did not produce an aborted terminal run')
    return snapshots.run(run, registry)
end

---Force-aborts one active run through authorized operator recovery.
---@param request table
---@param dependencies table
---@return table
function M.operator_abort(request, dependencies)
    local registry = require_registry(dependencies)
    local run = scheduler.authorize_operator_abort(registry, request,
        scheduler_context(dependencies))
    assert(type(dependencies) == 'table' and
        type(dependencies.abort_active) == 'function',
        'operator abort requires the service host cleanup boundary')
    dependencies.abort_active({
        service_instance_id=run.service_instance_id,
        project_id=run.project_id,
        run_id=run.run_id,
        generation=run.generation,
    }, request.reason)
    assert(run.terminal and run.state == RunState.ABORTED,
        'operator abort did not produce an aborted terminal run')
    return snapshots.run(run, registry)
end

---Expires due queue and execution leases through their distinct paths.
---@param dependencies table
---@return table
function M.expire_leases(dependencies)
    local registry = require_registry(dependencies)
    local queue_outcomes = scheduler.expire_due_queue(
        registry, scheduler_context(dependencies))
    local expired_queue = {}
    for _, outcome in ipairs(queue_outcomes) do
        cancel_lease_timer(outcome.run, dependencies)
        table.insert(expired_queue, outcome.identity)
    end

    local active = scheduler.claim_expired_active(
        registry, scheduler_context(dependencies))
    local active_identity
    if active ~= nil then
        cancel_lease_timer(active, dependencies)
        active_identity = {
            service_instance_id=active.service_instance_id,
            project_id=active.project_id,
            run_id=active.run_id,
            generation=active.generation,
        }
        assert(type(dependencies.abort_active) == 'function',
            'execution lease expiry requires the service host cleanup boundary')
        dependencies.abort_active(active_identity,
            ('execution lease expired after %d ms')
                :format(active.execution_lease.timeout_ms))
        assert(active.terminal and active.state == RunState.ABORTED,
            'execution lease expiry did not abort the active run')
    end
    if (#expired_queue > 0 or active_identity ~= nil) and
            type(dependencies.after_lease_expiry) == 'function' then
        dependencies.after_lease_expiry()
    end
    return {
        expired_queue=expired_queue,
        expired_active=active_identity,
    }
end

---Records terminal cleanup and releases the active executor generation.
---The service-owned host will call this seam after native lifecycle handling.
---@param run_id string
---@param generation integer
---@param terminal_state DwarfSpecRunState
---@param cleanup_confirmed boolean
---@param reason string|nil
---@param dependencies table|nil
---@return table
function M.complete_active(run_id, generation, terminal_state,
        cleanup_confirmed, reason, dependencies)
    local registry = require_registry(dependencies)
    local outcome = scheduler.finish_active(registry, run_id, generation,
        terminal_state, cleanup_confirmed, reason,
        scheduler_context(dependencies))
    cancel_lease_timer(outcome.run, dependencies)
    return {
        finished=outcome.finished,
        identity=outcome.identity,
        snapshot=snapshots.run(outcome.run, registry),
        scheduler=snapshots.scheduler(registry),
    }
end

---Clears executor quarantine after explicit authoritative clean-state proof.
---@param request table
---@param dependencies table|nil
---@return table
function M.recover_executor(request, dependencies)
    local registry = require_registry(dependencies)
    local outcome = scheduler.recover_executor(registry, request,
        scheduler_context(dependencies))
    return {
        recovered=outcome.recovered,
        scheduler=snapshots.scheduler(registry),
    }
end

---Acknowledges one exact owner-retained terminal result after persistence.
---@param request table
---@param dependencies table|nil
---@return table
function M.acknowledge(request, dependencies)
    local registry = require_registry(dependencies)
    local run = scheduler.acknowledge(registry, request,
        scheduler_context(dependencies))
    return snapshots.run(run, registry)
end

---Explicitly discards one exact terminal result through operator authority.
---@param request table
---@param dependencies table|nil
---@return table
function M.discard(request, dependencies)
    local registry = require_registry(dependencies)
    local run = scheduler.discard(registry, request,
        scheduler_context(dependencies))
    return snapshots.run(run, registry)
end

---Returns the retained latest terminal result for one project.
---@param project_id string
---@param dependencies table|nil
---@return table|nil
function M.latest_result(project_id, dependencies)
    assert(type(project_id) == 'string' and project_id ~= '',
        'latest-result project id must be a nonempty string')
    local registry = require_registry(dependencies)
    local run_id = registry.latest_terminal_results[project_id]
    if run_id == nil then return nil end
    local run = assert(registry.runs[run_id],
        'latest terminal result references an unknown run')
    return snapshots.run(run, registry)
end

return M
