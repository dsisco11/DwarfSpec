-- Read-only and explicitly authorized control surface for live integration.

local operation, run_id, cursor_text = ...
assert(operation, 'integration control operation is required')
local cursor = tonumber(cursor_text) or 0
local JSON_NULL = '\0'

---Configures pure-Lua lookup and derives the repository root.
---@return string
local function repository_root()
    local source = debug.getinfo(1, 'S').source:gsub('^@', '')
    local root = assert(source:match(
        '^(.*)[/\\]tests[/\\]integration[/\\]support[/\\]control%.lua$'),
        'could not derive DwarfSpec root from ' .. source)
    package.path = root .. '/src/?.lua;' .. root ..
        '/src/?/init.lua;' .. package.path
    return root
end

---Returns one bounded diagnostic string.
---@param value any
---@return string
local function bounded(value)
    local text = tostring(value):gsub('\r', '\\r'):gsub('\n', '\\n')
    if #text <= 1024 then return text end
    return text:sub(1, 1021) .. '...'
end

---Returns stable scheduler identity without exposing capabilities.
---@param registry table
---@return table
local function registry_identity(registry)
    local queue = {}
    for _, queued_run_id in ipairs(registry.queue or {}) do
        table.insert(queue, queued_run_id)
    end
    local retained_results = {}
    for project_id, terminal_run_id in
            pairs(registry.latest_terminal_results or {}) do
        retained_results[project_id] = terminal_run_id
    end
    local registered_projects = {}
    for project_id, project in pairs(registry.projects or {}) do
        table.insert(registered_projects, {
            project_id=project_id,
            normalized_project_root=project.normalized_project_root,
            outstanding_run_id=project.outstanding_run_id or JSON_NULL,
        })
    end
    ---Orders registered project diagnostics by stable service identifier.
    ---@param left table
    ---@param right table
    ---@return boolean
    local function project_before(left, right)
        return left.project_id < right.project_id
    end
    table.sort(registered_projects, project_before)
    return {
        service_instance_id=registry.service_instance_id,
        protocol_version=registry.protocol_version,
        package_root=registry.package_root,
        package_version=registry.package_version,
        generation=registry.generation,
        active_run_id=registry.active_run_id,
        queue=queue,
        quarantine=registry.quarantine,
        projects=registered_projects,
        latest_terminal_results=retained_results,
    }
end

---Returns bounded raw-resource diagnostics for one retained run.
---@param run table
---@return table
local function run_diagnostics(run)
    local pending = run.cleanup_registry and
        run.cleanup_module.pending_count(run.cleanup_registry) or 0
    return {
        state=run.state,
        terminal=run.terminal == true,
        cleanup_confirmed=run.cleanup_confirmed == true,
        cleanup_pending=pending,
        cleanup_running=run.cleanup_registry and
            run.cleanup_registry.cleaning == true or false,
        coroutine_active=run.coroutine ~= nil,
        scheduler_active=run.scheduler ~= nil,
        wait_active=run.outstanding_wait ~= nil,
        timer_active=run.scheduled_timeout_id ~= nil,
        mount_probe_active=run.mount_cleanup_probe ~= nil,
        mount_cleanup_state=run.mount_cleanup_state or JSON_NULL,
        module_environment_audit=run.module_environment_audit or JSON_NULL,
        pause_state=df and df.global and
            df.global.pause_state or JSON_NULL,
    }
end

local root = repository_root()
local host = assert(loadfile(root ..
    '/src/dwarfspec/automation/host.lua'))()
local registry = assert(dfhack.dwarfspec,
    'DwarfSpec service is not bootstrapped')

if operation == 'registry' then
    print('DWARFSPEC_HARNESS_JSON ' .. require('json').encode({
        registry=registry_identity(registry),
    }, {pretty=false, null=JSON_NULL}))
elseif operation == 'snapshot' then
    local run = host.observe(assert(run_id, 'run id is required'))
    local transport = host.transport(run.run_id, cursor)
    transport.harness = {
        registry=registry_identity(registry),
        run=run_diagnostics(run),
    }
    print('DWARFSPEC_JSON ' .. host.encode_transport(transport))
elseif operation == 'incompatible' then
    local service = assert(loadfile(root ..
        '/src/dwarfspec/automation/service.lua'))()
    local before = registry_identity(registry)
    local ok, failure = pcall(service.bootstrap, {
        protocol_version=999,
        package_root=registry.package_root,
        package_version='incompatible-integration-client',
    }, {namespace=dfhack})
    local after = registry_identity(assert(dfhack.dwarfspec))
    print('DWARFSPEC_HARNESS_JSON ' .. require('json').encode({
        rejected=not ok,
        error=ok and nil or bounded(failure),
        before=before,
        after=after,
    }, {pretty=false}))
elseif operation == 'compatible-reload' then
    local reloaded = assert(loadfile(root ..
        '/src/dwarfspec/automation/host.lua'))()
    local transport = reloaded.transport(
        assert(run_id, 'run id is required'), cursor)
    transport.harness = {
        registry=registry_identity(assert(dfhack.dwarfspec)),
        run=run_diagnostics(reloaded.observe(run_id)),
    }
    print('DWARFSPEC_JSON ' .. reloaded.encode_transport(transport))
else
    error('unknown integration control operation: ' .. operation)
end
