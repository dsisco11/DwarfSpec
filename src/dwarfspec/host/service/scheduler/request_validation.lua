-- Mutation-free request and scheduler identity validation.

local events = require('dwarfspec.protocol.events')
local OwnerKind = require('dwarfspec.protocol.enums.owner_kinds')
local projects = require('dwarfspec.host.service.projects')
local ResultPolicy = require('dwarfspec.protocol.enums.result_policies')

local M = {}
local SUBMISSION_FIELDS = {selection=true, request_key=true, owner_kind=true,
    queue_lease_ms=true, execution_lease_ms=true, lease_check_frames=true}

---Returns one validated monotonic timestamp.
function M.current_time(context)
    local value = context.now_ms()
    assert(type(value) == 'number' and value >= 0,
        'scheduler clock returned an invalid timestamp')
    return value
end

---Validates a deterministic selection and returns a detached copy.
function M.selection(selection)
    assert(type(selection) == 'table', 'run selection must be a table')
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

---Returns whether two JSON-safe values are structurally equal.
function M.json_equal(left, right)
    if type(left) ~= type(right) then return false end
    if type(left) ~= 'table' then return left == right end
    for key, value in pairs(left) do
        if not M.json_equal(value, right[key]) then return false end
    end
    for key in pairs(right) do if left[key] == nil then return false end end
    return true
end

---Returns whether an idempotent retry matches its original request.
function M.matches_request_key(run, normalized)
    return run.owner_kind == normalized.owner_kind and
        run.queue_lease.timeout_ms == normalized.queue_lease_ms and
        run.execution_lease.timeout_ms == normalized.execution_lease_ms and
        run.lease_check_frames == normalized.lease_check_frames and
        run.result_path_identity == normalized.result_path_identity and
        run.result_policy == normalized.project.result_policy and
        M.json_equal(run.selection, normalized.selection)
end

---Returns a public run identity without its owner capability.
function M.public_identity(run)
    return {service_instance_id=run.service_instance_id,
        project_id=run.project_id, run_id=run.run_id,
        generation=run.generation}
end

---Validates a run's immutable service and project ownership identity.
function M.run_identity(registry, run)
    assert(run.service_instance_id == registry.service_instance_id,
        'automation run belongs to a different service instance')
    local project = assert(registry.projects[run.project_id],
        'automation run belongs to an unregistered project')
    assert(project.outstanding_run_id == run.run_id,
        'automation project does not own the requested run')
    assert(type(run.generation) == 'number' and run.generation > 0 and
        run.generation % 1 == 0, 'automation run has an invalid generation')
end

---Returns an exact owner-capability-authorized run without mutation.
function M.authorize_owner(registry, request, operation)
    assert(type(request) == 'table', operation .. ' request must be a table')
    assert(request.service_instance_id == registry.service_instance_id,
        operation .. ' service identity does not match')
    assert(type(request.project_id) == 'string' and request.project_id ~= '',
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
    M.run_identity(registry, run)
    return run
end

---Returns one exact run without authorizing owner mutation.
function M.exact_run(registry, request, operation)
    assert(type(request) == 'table', operation .. ' request must be a table')
    assert(request.service_instance_id == registry.service_instance_id,
        operation .. ' service identity does not match')
    local run = assert(registry.runs[request.run_id],
        'automation run was not found: ' .. tostring(request.run_id))
    assert(run.project_id == request.project_id,
        operation .. ' project identity does not match run')
    assert(run.generation == request.generation,
        operation .. ' generation does not match run')
    M.run_identity(registry, run)
    return run
end

---Authorizes an operator request without changing scheduler state.
---@param context table
---@param request table
---@param operation string
---@param run table
---@param labels table|nil
---@return string
function M.authorize_operator(context, request, operation, run, labels)
    labels = labels or {
        request=operation,
        authority=operation .. ' operator authority',
    }
    assert(type(request.authority) == 'table',
        labels.request .. ' requires operator authority')
    events.copy_json(request.authority, labels.authority)
    assert(type(context.authorize_operator) == 'function',
        labels.request .. ' requires an authority verifier')
    local authorized, label = context.authorize_operator(
        request.authority, operation, run)
    assert(authorized == true, label or labels.authority .. ' was rejected')
    return tostring(label or 'authorized operator')
end

---Returns the normalized result path owned by one project policy.
function M.normalize_result_path(project, filesystem)
    if project.result_policy == ResultPolicy.NONE then return nil, nil end
    assert(project.result_policy == ResultPolicy.FILE,
        'registered project has unsupported result policy')
    return projects.normalize_file_path(project.result_path,
        project.normalized_project_root, filesystem)
end

---Finds an outstanding run reserving a canonical result path.
function M.find_result_path_owner(registry, identity)
    if identity == nil then return nil end
    for _, run in pairs(registry.runs) do
        if run.acknowledged ~= true and run.discarded ~= true and
                run.result_path_identity == identity then return run end
    end
end

---Validates and normalizes a submission without mutation.
function M.submission(registry, project_id, request, context)
    assert(type(project_id) == 'string' and project_id ~= '',
        'submission project id must be a nonempty string')
    assert(type(request) == 'table', 'run submission request must be a table')
    events.copy_json(request, 'run submission request')
    for field in pairs(request) do
        assert(SUBMISSION_FIELDS[field] == true,
            'run submission request has unsupported field: ' .. tostring(field))
    end
    local project = registry.projects[project_id]
    assert(type(project) == 'table',
        'registered project was not found: ' .. project_id)
    assert(project.client_compatibility.protocol == registry.protocol_version,
        'registered project protocol is no longer compatible')
    assert(project.client_compatibility.package_version == registry.package_version,
        'registered project package version is no longer compatible')
    local request_key = request.request_key
    if request_key ~= nil then
        assert(type(request_key) == 'string' and #request_key >= 16 and
            #request_key <= 256,
            'run request key must contain between 16 and 256 bytes')
    end
    local owner_kind = request.owner_kind or OwnerKind.EXTERNAL
    assert(owner_kind == OwnerKind.EXTERNAL or owner_kind == OwnerKind.IN_PROCESS,
        'run owner kind must be a supported OwnerKind')
    local function lease(value, name)
        value = value or 5000
        assert(type(value) == 'number' and value >= 1 and value <= 86400000 and
            value % 1 == 0, name ..
            ' must be an integer between 1 and 86400000 milliseconds')
        return value
    end
    local frames = request.lease_check_frames or 30
    assert(type(frames) == 'number' and frames >= 1 and frames <= 1000000 and
        frames % 1 == 0,
        'lease check interval must be a positive bounded integer')
    local result_path, result_identity = M.normalize_result_path(
        project, context.filesystem)
    return {project=project, selection=M.selection(request.selection),
        request_key=request_key, owner_kind=owner_kind,
        queue_lease_ms=lease(request.queue_lease_ms, 'queue lease duration'),
        execution_lease_ms=lease(request.execution_lease_ms,
            'execution lease duration'), lease_check_frames=frames,
        result_path=result_path, result_path_identity=result_identity}
end

return M
