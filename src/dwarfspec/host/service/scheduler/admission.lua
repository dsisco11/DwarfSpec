-- Admission policy for scheduler run submissions.

local events = require('dwarfspec.protocol.events')
local OwnerKind = require('dwarfspec.protocol.enums.owner_kinds')
local RunState = require('dwarfspec.protocol.enums.run_states')
local FailureKind = require('dwarfspec.protocol.enums.scheduler_failure_kinds')
local transitions = require('dwarfspec.host.service.scheduler.transitions')
local validation = require('dwarfspec.host.service.scheduler.request_validation')

local M = {}

---Returns an empty Busted result-count record.
local function empty_counts()
    return {successes=0, failures=0, errors=0, pending=0}
end

---Returns one classified admission rejection.
local function rejected(kind, run, reason)
    return {accepted=false, kind=kind, reason=reason,
        identity=validation.public_identity(run), run=run}
end

---Allocates a unique run identifier without mutating the registry.
local function allocate_run_id(registry, generation, context)
    local run_id = context.new_run_id(generation)
    assert(type(run_id) == 'string' and run_id ~= '',
        'run id generator returned an invalid identifier')
    assert(registry.runs[run_id] == nil,
        'run id generator returned an existing identifier')
    return run_id
end

---Allocates a unique owner capability without mutating the registry.
local function allocate_owner_capability(registry, context, run_id, generation)
    for _ = 1, 128 do
        local capability = context.new_owner_capability(run_id, generation)
        assert(type(capability) == 'string' and #capability >= 32 and
            #capability <= 512,
            'owner capability generator returned an invalid capability')
        local available = true
        for _, run in pairs(registry.runs) do
            if run.owner_capability == capability then available = false break end
        end
        if available then return capability end
    end
    error('owner capability generator repeatedly returned existing values')
end

---Admits one run or returns a stable classified conflict.
function M.submit(registry, project_id, request, context)
    local normalized = validation.submission(registry, project_id, request,
        context)
    local project = normalized.project
    if normalized.request_key then
        local prior_id = (project.request_keys or {})[normalized.request_key]
        if prior_id then
            local prior = assert(registry.runs[prior_id],
                'project request key references an unknown run')
            if not validation.matches_request_key(prior, normalized) then
                return rejected(FailureKind.REQUEST_KEY_CONFLICT, prior,
                    'request key is already bound to a different request')
            end
            return {accepted=true, reused=true,
                owner_capability=prior.owner_capability,
                identity=validation.public_identity(prior), run=prior}
        end
    end
    if project.outstanding_run_id then
        local outstanding = assert(registry.runs[project.outstanding_run_id],
            'project outstanding run identity is invalid')
        return rejected(FailureKind.PROJECT_BUSY, outstanding,
            'project already owns an outstanding run')
    end
    local path_owner = validation.find_result_path_owner(registry,
        normalized.result_path_identity)
    if path_owner then return rejected(FailureKind.RESULT_PATH_BUSY, path_owner,
        'result path is owned by another outstanding run') end

    local timestamp_ms = validation.current_time(context)
    local generation = registry.generation + 1
    local run_id = allocate_run_id(registry, generation, context)
    local capability = allocate_owner_capability(registry, context,
        run_id, generation)
    local queue_lease = {active=normalized.owner_kind == OwnerKind.EXTERNAL,
        timeout_ms=normalized.queue_lease_ms}
    if queue_lease.active then
        queue_lease.renewed_at_ms = timestamp_ms
        queue_lease.expires_at_ms = timestamp_ms + normalized.queue_lease_ms
    else queue_lease.service_owned = true end
    local run = {service_instance_id=registry.service_instance_id,
        project_id=project_id, run_id=run_id, generation=generation,
        state=RunState.QUEUED, terminal=false,
        submitted_at_ms=timestamp_ms, selection=normalized.selection,
        request_key=normalized.request_key, owner_kind=normalized.owner_kind,
        owner_capability=capability,
        lease_check_frames=normalized.lease_check_frames,
        result_policy=project.result_policy, result_path=normalized.result_path,
        result_path_identity=normalized.result_path_identity,
        queue_lease=queue_lease,
        execution_lease={active=false,
            timeout_ms=normalized.execution_lease_ms,
            service_owned=normalized.owner_kind == OwnerKind.IN_PROCESS},
        cleanup_confirmed=false, mount_cleanup_verified=false,
        counts=empty_counts(), totals=empty_counts(), failures={},
        event_journal=events.new_journal({
            service_instance_id=registry.service_instance_id,
            project_id=project_id, run_id=run_id, generation=generation,
            admitted_at_ms=timestamp_ms})}
    transitions.queue(registry, project, run, timestamp_ms)
    return {accepted=true, reused=false, owner_capability=capability,
        identity=validation.public_identity(run), run=run}
end

return M
