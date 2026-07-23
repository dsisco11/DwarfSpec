-- Process-wide multi-project automation service runtime and public boundary.

local projects = require('dwarfspec.automation.projects')

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
    return projects.copy_json({
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

return M
