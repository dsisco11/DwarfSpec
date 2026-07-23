-- Process-wide multi-project automation service runtime and public boundary.

local projects = require('dwarfspec.automation.projects')
local events = require('dwarfspec.automation.events')
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
local function new_owner_capability(dependencies)
    if dependencies and dependencies.new_owner_capability then
        return dependencies.new_owner_capability()
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
        new_owner_capability=function()
            return new_owner_capability(dependencies)
        end,
        validate_activation=dependencies and
            dependencies.validate_activation or nil,
        verify_clean_state=dependencies and
            dependencies.verify_clean_state or nil,
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
    local outcome = scheduler.activate_next(registry,
        scheduler_context(dependencies))
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

---Cancels one owned queued run without invoking native cleanup.
---@param run_id string
---@param owner_capability string
---@param reason string
---@param dependencies table|nil
---@return table
function M.cancel(run_id, owner_capability, reason, dependencies)
    local registry = require_registry(dependencies)
    local outcome = scheduler.cancel(registry, run_id, owner_capability,
        reason, scheduler_context(dependencies))
    return {
        cancelled=outcome.cancelled,
        identity=outcome.identity,
        snapshot=snapshots.run(outcome.run, registry),
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

---Releases a terminal reservation after version 1 status observation.
---This adapter-only bridge is removed when explicit acknowledgement ships.
---@param run_id string
---@param generation integer
---@param owner_capability string
---@param dependencies table|nil
---@return table
function M.acknowledge_compatibility(run_id, generation, owner_capability,
        dependencies)
    local registry = require_registry(dependencies)
    local run = scheduler.acknowledge_compatibility(registry, run_id,
        generation, owner_capability)
    return snapshots.run(run, registry)
end

return M
