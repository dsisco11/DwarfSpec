-- Immutable public snapshots derived from service-owned automation state.

local events = require('dwarfspec.automation.events')
local OwnerKind = require('dwarfspec.automation.owner_kinds')
local schemas = require('dwarfspec.automation.schemas')

local M = {}

---Returns an empty Busted count record.
---@return table
local function empty_counts()
    return {successes=0, failures=0, errors=0, pending=0}
end

---Returns one run's current one-based queue position.
---@param registry table
---@param run_id string
---@return integer|nil
local function queue_position(registry, run_id)
    for index, queued_run_id in ipairs(registry.queue or {}) do
        if queued_run_id == run_id then return index end
    end
    return nil
end

---Returns the last sequence retained by one run.
---@param run table
---@return integer
local function last_sequence(run)
    if run.event_journal and run.event_journal.events then
        return #run.event_journal.events
    end
    if type(run.events) == 'table' then return #run.events end
    return run.last_sequence or 0
end

---Returns an immutable version 2 snapshot of one run.
---@param run table
---@param registry table
---@return table
function M.run(run, registry)
    assert(type(run) == 'table', 'automation run record must be a table')
    assert(type(registry) == 'table',
        'automation service registry must be a table')
    local snapshot = {
        schema='dwarfspec.run.v2',
        protocol_version=2,
        service_instance_id=run.service_instance_id or
            registry.service_instance_id,
        project_id=run.project_id,
        run_id=run.run_id,
        generation=run.generation,
        state=run.state,
        terminal=run.terminal == true,
        queue_position=queue_position(registry, run.run_id),
        submitted_at_ms=run.submitted_at_ms,
        activated_at_ms=run.activated_at_ms,
        queue_wait_ms=run.queue_wait_ms,
        current_repeat=run.current_repeat,
        current_test=run.current_test,
        counts=run.counts or empty_counts(),
        totals=run.totals or empty_counts(),
        last_sequence=last_sequence(run),
        queue_lease=run.queue_lease or {active=false},
        execution_lease=run.execution_lease or {active=false},
        owner_kind=run.owner_kind or OwnerKind.EXTERNAL,
        acknowledged=run.acknowledged == true,
        discarded=run.discarded == true,
        terminal_reason=run.terminal_reason,
        cleanup_confirmed=run.cleanup_confirmed == true,
        cleanup_reason=run.cleanup_reason,
        mount_cleanup_verified=run.mount_cleanup_verified == true,
        host_error=run.host_error,
        failures=run.failures or {},
    }
    schemas.validate_run(snapshot)
    return events.copy_json(snapshot, 'run snapshot')
end

---Orders retained run records from newest to oldest generation.
---@param left table
---@param right table
---@return boolean
local function newer_generation(left, right)
    return left.generation > right.generation
end

---Returns one detached summary for a retained run.
---@param run table
---@param registry table
---@return table
local function history_entry(run, registry)
    local project = registry.projects[run.project_id]
    return {
        run_id=run.run_id,
        project_id=run.project_id,
        project_name=project and project.display_name or nil,
        project_root=project and project.normalized_project_root or nil,
        generation=run.generation,
        state=run.state,
        terminal=run.terminal == true,
        submitted_at_ms=run.submitted_at_ms,
        activated_at_ms=run.activated_at_ms,
        finished_at_ms=run.finished_at_ms,
        cleanup_confirmed=run.cleanup_confirmed == true,
        acknowledged=run.acknowledged == true,
        discarded=run.discarded == true,
        log_line_count=#(run.output_lines or {}),
    }
end

---Returns immutable retained-run summaries in newest-first order.
---@param registry table
---@return table[]
function M.history(registry)
    assert(type(registry) == 'table',
        'automation service registry must be a table')
    local runs = {}
    for _, run in pairs(registry.runs or {}) do
        table.insert(runs, history_entry(run, registry))
    end
    table.sort(runs, newer_generation)
    return events.copy_json(runs, 'run history')
end

---Returns one public scheduler queue entry.
---@param registry table
---@param run_id string
---@return table
local function queue_entry(registry, run_id)
    local run = registry.runs[run_id]
    assert(type(run) == 'table',
        'scheduler queue references unknown run: ' .. tostring(run_id))
    return {
        run_id=run_id,
        project_id=run.project_id,
    }
end

---Orders project summaries by registration time and stable identifier.
---@param left table
---@param right table
---@return boolean
local function registered_before(left, right)
    if left.registered_at ~= right.registered_at then
        return left.registered_at < right.registered_at
    end
    return left.project_id < right.project_id
end

---Returns bounded project summaries in deterministic registration order.
---@param registry table
---@return table[]
local function project_summaries(registry)
    local summaries = {}
    for _, project in pairs(registry.projects or {}) do
        table.insert(summaries, {
            project_id=project.project_id,
            normalized_project_root=project.normalized_project_root,
            display_name=project.display_name,
            normalized_configuration=project.normalized_configuration,
            result_path=project.result_path,
            result_policy=project.result_policy,
            client_compatibility=project.client_compatibility,
            registered_at=project.registered_at,
            refreshed_at=project.refreshed_at,
            outstanding_run_id=project.outstanding_run_id,
        })
    end
    table.sort(summaries, registered_before)
    return summaries
end

---Returns an immutable version 2 scheduler snapshot.
---@param registry table
---@return table
function M.scheduler(registry)
    assert(type(registry) == 'table',
        'automation service registry must be a table')
    local queue = {}
    for _, run_id in ipairs(registry.queue or {}) do
        table.insert(queue, queue_entry(registry, run_id))
    end

    local active_run = registry.active_run_id and
        registry.runs[registry.active_run_id] or nil
    local snapshot = {
        schema='dwarfspec.scheduler.v2',
        protocol_version=registry.protocol_version,
        service_instance_id=registry.service_instance_id,
        package_root=registry.package_root,
        package_version=registry.package_version,
        active_run_id=registry.active_run_id,
        active_project_id=active_run and active_run.project_id or nil,
        queue=queue,
        projects=project_summaries(registry),
        quarantine=registry.quarantine,
    }
    schemas.validate_scheduler(snapshot)
    return events.copy_json(snapshot, 'scheduler snapshot')
end

return M
