-- Service-owned Busted host for DFHack core-context automation.

local RunState = require('dwarfspec.automation.run_states')
local EventType = require('dwarfspec.automation.event_types')
local OwnerKind = require('dwarfspec.automation.owner_kinds')
local ResultPolicy = require('dwarfspec.automation.result_policies')
local SchedulerFailureKind =
    require('dwarfspec.automation.scheduler_failure_kinds')
local service = require('dwarfspec.automation.service')

local M = {
    protocol_version=1,
    service_protocol_version=2,
    package_version='0.2.0',
}

local RUN_STATE_TERMINAL = {
    [RunState.QUEUED]=false,
    [RunState.STARTING]=false,
    [RunState.RUNNING]=false,
    [RunState.CLEANING]=false,
    [RunState.PASSED]=true,
    [RunState.FAILED]=true,
    [RunState.ABORTED]=true,
    [RunState.CANCELLED]=true,
}

local TEST_DEPENDENCY_ROOTS = {
    busted=true,
    cliargs=true,
    dkjson=true,
    lfs=true,
    luassert=true,
    mediator=true,
    pl=true,
    say=true,
    system=true,
    term=true,
}

---Clears cached test-runtime modules before loading one package tree's copies.
---@param loaded table|nil
function M.clear_dependency_modules(loaded)
    loaded = loaded or package.loaded
    for name in pairs(loaded) do
        local root = name:match('^([^.]+)')
        if TEST_DEPENDENCY_ROOTS[root] then loaded[name] = nil end
    end
end

---Returns a repository path using the active platform separator.
---@param root string
---@param relative_path string
---@return string
local function join_path(root, relative_path)
    local separator = package.config:sub(1, 1)
    return root .. separator .. relative_path:gsub('[/\\]', separator)
end

---Loads an installed DwarfSpec module or its source-tree equivalent.
---@param package_root string
---@param module_name string
---@param source_relative string
---@return table
local function load_automation_module(package_root, module_name,
        source_relative)
    local source_path = join_path(package_root, source_relative)
    local source_file = io.open(source_path, 'rb')
    if source_file then
        source_file:close()
        return assert(loadfile(source_path))()
    end
    local ok, module = pcall(require, module_name)
    if ok then return module end
    error(module, 0)
end

---Returns whether a semicolon-delimited Lua search path contains an entry.
---@param search_path string
---@param entry string
---@return boolean
local function search_path_contains(search_path, entry)
    for candidate in search_path:gmatch('[^;]+') do
        if candidate == entry then return true end
    end
    return false
end

---Returns the current world frame when a world is loaded.
---@return integer|nil
local function current_frame()
    return df and df.global and df.global.world and
        df.global.world.frame_counter or nil
end

---Returns current focus and viewscreen context for operational wait errors.
---@return table
local function current_diagnostics()
    local focus = '<unavailable>'
    local screen = '<unavailable>'
    if dfhack.gui and type(dfhack.gui.getCurFocus) == 'function' then
        local ok, value = pcall(dfhack.gui.getCurFocus)
        if ok and type(value) == 'table' then
            focus = table.concat(value, ' > ')
        elseif ok then
            focus = value
        end
    end
    if dfhack.gui and type(dfhack.gui.getCurViewscreen) == 'function' then
        local ok, value = pcall(dfhack.gui.getCurViewscreen, true)
        if ok then
            if type(value) == 'userdata' and value._type then
                screen = tostring(value._type)
            else
                screen = tostring(value)
            end
        end
    end
    return {focus=focus, screen=screen}
end

---Returns whether a run has reached a terminal state.
---@param run table
---@return boolean
function M.is_terminal(run)
    return RUN_STATE_TERMINAL[run.state] == true
end

---Validates a caller-provided run identifier.
---@param run_id string
local function validate_run_id(run_id)
    if not run_id:match('^[%w_.-]+$') then
        error('run id must contain only letters, digits, dot, underscore, or dash')
    end
end

---Returns the compatible process-wide service registry.
---@return table
local function get_registry()
    local registry = dfhack.dwarfspec
    assert(type(registry) == 'table' and
        registry.protocol_version == M.service_protocol_version and
        registry.schema == service.schema,
        'compatible automation service has not been bootstrapped')
    return registry
end

---Verifies that a quarantined generation owns no remaining live resources.
---@param proof table
---@return boolean, string
local function verify_executor_clean_state(proof)
    if type(proof) ~= 'table' or proof.local_dfhack_run ~= true then
        return false, 'executor recovery requires local dfhack-run proof'
    end
    local registry = get_registry()
    local quarantine = registry.quarantine
    if type(quarantine) ~= 'table' or quarantine.active ~= true then
        return false, 'automation executor is not quarantined'
    end
    local run = registry.runs[quarantine.run_id]
    if type(run) ~= 'table' or run.generation ~= quarantine.generation then
        return false, 'quarantined automation generation was not found'
    end
    if registry.active_run_id ~= nil or not run.terminal then
        return false, 'quarantined automation generation is still active'
    end
    local pending = run.cleanup_registry and
        run.cleanup_module.pending_count(run.cleanup_registry) or 0
    if pending ~= 0 or
            run.cleanup_registry and run.cleanup_registry.cleaning then
        return false, 'quarantined cleanup registry is not drained'
    end
    if run.coroutine ~= nil or run.scheduler ~= nil or
            run.outstanding_wait ~= nil or
            run.scheduled_timeout_id ~= nil then
        return false, 'quarantined asynchronous execution remains active'
    end
    if run.mount_cleanup_probe ~= nil then
        return false, 'quarantined mount cleanup probe remains active'
    end
    local mount = run.mount_cleanup_state
    if mount and (mount.current_mount_id ~= nil or
            mount.active_screen_count ~= 0 or mount.subject_count ~= 0 or
            mount.pointer_active == true or mount.verified ~= true) then
        return false, 'quarantined mount state is not clean'
    end
    local modules = run.module_environment_audit
    if modules and (modules.restored ~= true or
            modules.path_restored ~= true) then
        return false, 'quarantined project module environment is not restored'
    end
    return true, 'quarantined generation has no remaining live resources'
end

---Returns the filesystem surface used for service path validation.
---@return table|nil
local function service_filesystem()
    local filesystem = dfhack.filesystem
    if type(filesystem) ~= 'table' or
            type(filesystem.getcwd) ~= 'function' or
            type(filesystem.isdir) ~= 'function' then
        return nil
    end
    return {
        currentdir=filesystem.getcwd,
        isdir=filesystem.isdir,
        case_insensitive=package.config:sub(1, 1) == '\\',
    }
end

---Returns dependencies for service mutations in the live host.
---@param run_id string|nil
---@return table
local function service_dependencies(run_id)
    local dependencies = {
        namespace=dfhack,
        filesystem=service_filesystem(),
        now_ms=dfhack.getTickCount,
        schedule_lease_timer=function(run, delay_ms, callback)
            assert(type(delay_ms) == 'number' and delay_ms >= 1,
                'lease timer delay must be positive')
            return dfhack.timeout(run.lease_check_frames or 30,
                'frames', callback)
        end,
        cancel_lease_timer=function(timer_id)
            return dfhack.timeout_active(timer_id, nil)
        end,
        abort_active=function(identity, reason)
            return M.expire_active(identity.run_id,
                identity.generation, reason)
        end,
        after_lease_expiry=function()
            M.activate_next()
        end,
        authorize_operator=function(authority)
            local authorized = type(authority) == 'table' and
                authority.local_dfhack_run == true
            return authorized, authorized and 'local dfhack-run operator' or
                'local dfhack-run operator authority was rejected'
        end,
        verify_clean_state=verify_executor_clean_state,
    }
    if run_id ~= nil then
        dependencies.new_run_id=function()
            return run_id
        end
        dependencies.new_owner_capability=function()
            return ('owner-%08x-%08x-%08x-%08x-%08x'):format(
                math.random(0, 0x7fffffff),
                math.random(0, 0x7fffffff),
                math.random(0, 0x7fffffff),
                math.random(0, 0x7fffffff),
                math.floor(dfhack.getTickCount()) % 0x7fffffff)
        end
    end
    return dependencies
end

---Returns whether a file can be opened for reading.
---@param path string
---@return boolean
local function is_file(path)
    local file = io.open(path, 'rb')
    if not file then return false end
    file:close()
    return true
end

---Resolves the shared Lua module root for source and installed layouts.
---@param package_root string
---@return string
local function lua_module_root(package_root)
    if is_file(join_path(package_root, 'busted/core.lua')) then
        return package_root
    end
    local lua_version = assert(_VERSION:match('Lua (%d+%.%d+)'),
        'could not determine the active Lua version from ' .. tostring(_VERSION))
    return join_path(package_root,
        '.luarocks/share/lua/' .. lua_version)
end

---Configures pinned Lua dependencies and DFHack-native adapters.
---@param package_root string
---@param configured_lua_root string|nil
---@return string[]
local function configure_dependencies(package_root, configured_lua_root)
    local separator = package.config:sub(1, 1)
    local lua_root = configured_lua_root or lua_module_root(package_root)
    local source_entries = {
        lua_root .. separator .. '?.lua',
        lua_root .. separator .. '?' .. separator .. 'init.lua',
    }
    for index = #source_entries, 1, -1 do
        local entry = source_entries[index]
        if not search_path_contains(package.path, entry) then
            package.path = entry .. ';' .. package.path
        end
    end

    M.clear_dependency_modules()

    local system_adapter = load_automation_module(package_root,
        'dwarfspec.automation.system_adapter',
        'tests/automation/support/system_adapter.lua')
    local lfs_adapter = load_automation_module(package_root,
        'dwarfspec.automation.lfs_adapter',
        'tests/automation/support/lfs_adapter.lua')
    package.preload.system = function() return system_adapter end
    package.preload.lfs = function() return lfs_adapter end
    package.loaded.system = system_adapter
    package.loaded.lfs = lfs_adapter

    return source_entries
end

---Installs project-root module lookup and returns cleanup plus an audit record.
---@param project_root string
---@param protected_entries string[]
---@param runtime_package table|nil
---@return function, table
function M.configure_project_modules(project_root, protected_entries,
        runtime_package)
    assert(type(project_root) == 'string' and project_root ~= '',
        'project root must be a nonempty string')
    assert(type(protected_entries) == 'table',
        'protected package paths must be a table')
    runtime_package = runtime_package or package
    assert(type(runtime_package.path) == 'string' and
        type(runtime_package.loaded) == 'table' and
        type(runtime_package.searchpath) == 'function',
        'runtime package must provide path, loaded, and searchpath')

    local separator = package.config:sub(1, 1)
    local project_entries = {
        project_root .. separator .. '?.lua',
        project_root .. separator .. '?' .. separator .. 'init.lua',
    }
    local original_path = runtime_package.path
    local previously_loaded = {}
    for name in pairs(runtime_package.loaded) do
        previously_loaded[name] = true
    end

    local reordered = {}
    local included = {}
    local function include(entry)
        if entry ~= '' and not included[entry] then
            table.insert(reordered, entry)
            included[entry] = true
        end
    end
    for _, entry in ipairs(protected_entries) do include(entry) end
    for _, entry in ipairs(project_entries) do include(entry) end
    for entry in original_path:gmatch('[^;]+') do include(entry) end
    runtime_package.path = table.concat(reordered, ';')

    local audit = {
        original_path=original_path,
        project_entries=project_entries,
        restored=false,
        path_restored=false,
        evicted_modules={},
    }
    local restored = false
    return function()
        if restored then return end
        restored = true
        local project_path = table.concat(project_entries, ';')
        local protected_path = table.concat(protected_entries, ';')
        for name in pairs(runtime_package.loaded) do
            if type(name) == 'string' and not previously_loaded[name] and
                    runtime_package.searchpath(name, project_path) and
                    not runtime_package.searchpath(name, protected_path) then
                runtime_package.loaded[name] = nil
                table.insert(audit.evicted_modules, name)
            end
        end
        runtime_package.path = original_path
        audit.restored = true
        audit.path_restored = runtime_package.path == original_path
        table.sort(audit.evicted_modules)
    end, audit
end

---Normalizes a caller's optional scalar or dense-list filter value.
---@param value string|string[]|nil
---@return string[]
local function filter_list(value)
    if type(value) == 'table' then return value end
    if type(value) == 'string' and value ~= '' then return {value} end
    return {}
end

---Creates the standard Busted filter options for one automation run.
---@param options table
---@return table
function M.filter_options(options)
    return {
        tags=filter_list(options.tags),
        excludeTags=filter_list(options.exclude_tags),
        filter=filter_list(options.filters or options.filter),
        name=filter_list(options.names),
        filterOut=filter_list(options.filter_out),
        excludeNamesFile=nil,
        list=false,
        nokeepgoing=false,
        suppressPending=false,
    }
end

---Discovers only DwarfSpec live-spec files from the selected project root.
---@param project_root string
---@param loader function
---@param specs string[]|nil
---@return table
function M.discover_tests(project_root, loader, specs)
    assert(type(project_root) == 'string' and project_root ~= '',
        'project root must be a nonempty string')
    assert(type(loader) == 'function', 'live spec discovery requires a loader')
    specs = specs or {}
    assert(#specs > 0, 'no live specs were selected')
    for _, spec in ipairs(specs) do
        assert(type(spec) == 'string' and
            spec ~= '' and spec:match('%.lua$') and
            not spec:match('^[/\\]') and
            not spec:match('^[A-Za-z]:[/\\]') and spec ~= '..' and
            not spec:match('^%.%.[/\\]') and
            not spec:match('[/\\]%.%.[/\\]') and
            not spec:match('[/\\]%.%.$'),
            'live spec must name one safe project-relative Lua path')
    end
    local roots = {}
    for _, spec in ipairs(specs) do
        table.insert(roots, join_path(project_root, 'tests/' .. spec))
    end
    return loader(roots, {'%.lua$'}, {
        excludes={},
        recursive=true,
        verbose=false,
    })
end

---Installs run-scoped cleanup around every discovered Busted example.
---@param busted table
---@param reset function
function M.install_ds_lifecycle(busted, reset)
    assert(type(busted) == 'table' and type(busted.api) == 'table',
        'Busted root API is required for automation lifecycle hooks')
    assert(type(busted.api.before_each) == 'function' and
        type(busted.api.after_each) == 'function',
        'Busted before_each and after_each APIs are required')
    assert(type(reset) == 'function',
        'automation reset callback is required for lifecycle hooks')
    busted.api.before_each(function() reset('before example') end)
    busted.api.after_each(function() reset('after example') end)
end

---Executes one configured Busted suite synchronously inside its owner coroutine.
---@param repo_root string
---@param run table
---@param scheduler_module table
---@param scheduler table
local function execute_suite(package_root, project_root, run, scheduler_module,
        scheduler)
    local dependency_entries = configure_dependencies(package_root,
        run.options.lua_module_root)
    local busted = require('busted.core')()
    require('busted')(busted)
    local project_module = load_automation_module(package_root,
        'dwarfspec.automation.project',
        'tests/automation/support/project.lua')
    local project = project_module.new(project_root, package_root,
        dfhack.filesystem)
    local extensions_module = load_automation_module(package_root,
        'dwarfspec.automation.extensions',
        'tests/automation/support/extensions.lua')
    local restore_project_modules, module_audit =
        M.configure_project_modules(project_root, dependency_entries)
    run.module_environment_audit = module_audit
    run.cleanup_module.push(run.cleanup_registry,
        'project module environment', restore_project_modules)
    local extensions = extensions_module.load(project)
    local specs = run.options.specs or {}
    if #specs == 0 then
        local discovery = extensions.settings.discovery or {}
        local configured_glob = run.options.test_glob or
            discovery.test_glob
        specs = project_module.discover_specs(project, configured_glob)
    end
    local ds_factory = load_automation_module(package_root, 'dwarfspec.ds',
        'tests/automation/support/ds.lua')
    local ds, reset = ds_factory.new(package_root, project, scheduler_module,
        scheduler, run.cleanup_module, run.cleanup_registry, extensions)
    busted.export('ds', ds)
    M.install_ds_lifecycle(busted, reset)

    local output_factory = load_automation_module(package_root,
        'dwarfspec.automation.output_handler',
        'src/dwarfspec/automation/output_handler.lua')
    output_factory.new(busted, run, run.event_publisher)
    require('busted.modules.filter_loader')()(busted,
        M.filter_options(run.options))

    local loader = require('busted.modules.test_file_loader')(
        busted, {'lua'})
    run.discovered_files = M.discover_tests(project_root, loader, specs)

    busted.randomize = false
    busted.sort = true
    busted.randomseed = run.options.seed
    require('busted.execute')(busted)(run.options.repeat_count, {
        seed=run.options.seed,
        shuffle=false,
        sort=true,
    })
    busted.publish({'exit'})
end


---Cancels one run-owned timeout if it is still registered.
---@param timeout_id any
local function cancel_timeout(timeout_id)
    if timeout_id ~= nil then dfhack.timeout_active(timeout_id, nil) end
end

---Publishes one structured event through the run's generation guard.
---@param run table
---@param event_type DwarfSpecEventType
---@param payload table
local function publish_run_event(run, event_type, payload)
    assert(type(run.event_publisher) == 'table' and
        type(run.event_publisher.publish) == 'function',
        'active run does not own an event publisher')
    run.event_publisher.publish(event_type, payload)
end

---Records cleanup failures as host errors without hiding later failures.
---@param run table
---@param failures table[]
local function record_cleanup_failures(run, failures)
    for _, failure in ipairs(failures) do
        local failure_key = failure.id or failure
        if not run.recorded_cleanup_failures[failure_key] then
            run.recorded_cleanup_failures[failure_key] = true
            publish_run_event(run, EventType.CLEANUP_FAILED, {
                action_name=failure.name,
                reason=failure.reason,
                message=failure.message,
                trace=failure.message,
            })
            if not failure.reported_by_busted then
                local message = ('cleanup %s failed during %s: %s')
                    :format(failure.name, failure.reason, failure.message)
                table.insert(run.output_lines, 'CLEANUP_ERROR ' .. message)
                table.insert(run.failure_details, {
                    kind='error',
                    name='automation cleanup: ' .. failure.name,
                    message=message,
                    trace=failure.message,
                })
            end
        end
    end
end

---Cancels asynchronous work and drains all cleanup actions for a run.
---@param run table
---@param reason string
---@return boolean
local function clean_run(run, reason)
    if run.scheduler then
        run.scheduler_module.cancel(run.scheduler, reason)
        run.scheduler.owner = nil
        run.scheduler = nil
    end
    cancel_timeout(run.scheduled_timeout_id)
    run.scheduled_timeout_id = nil
    local ok = run.cleanup_module.run(run.cleanup_registry, reason)
    run.coroutine = nil
    run.suspended = false
    local mount_state
    local mount_ok = true
    if run.mount_cleanup_probe then
        local probe_ok, result = pcall(run.mount_cleanup_probe)
        if probe_ok and type(result) == 'table' then
            mount_state = result
            mount_ok = result.current_mount_id == nil and
                result.active_screen_count == 0 and
                result.subject_count == 0 and
                result.pointer_active ~= true
        else
            mount_ok = false
            mount_state = {probe_error=tostring(result)}
        end
        run.mount_cleanup_probe = nil
    end
    if mount_state then mount_state.verified = mount_ok end
    run.mount_cleanup_state = mount_state
    run.mount_cleanup_verified = mount_ok
    local history_ok = #run.cleanup_registry.failures == 0
    local module_audit = run.module_environment_audit
    local module_environment_ok = module_audit == nil or
        module_audit.restored == true and
        module_audit.path_restored == true
    run.cleanup_confirmed = ok and history_ok and mount_ok and
        module_environment_ok and
        run.cleanup_module.pending_count(run.cleanup_registry) == 0 and
        run.outstanding_wait == nil and run.coroutine == nil and
        run.scheduler == nil and run.scheduled_timeout_id == nil
    run.cleanup_reason = reason
    record_cleanup_failures(run, run.cleanup_registry.failures)
    if not mount_ok then
        local message = 'mount lifecycle verification failed during ' ..
            reason
        table.insert(run.output_lines, 'CLEANUP_ERROR ' .. message)
        table.insert(run.failure_details, {
            kind='error',
            name='automation cleanup: mount lifecycle verification',
            message=message,
            trace=mount_state and mount_state.probe_error or nil,
        })
        publish_run_event(run, EventType.CLEANUP_FAILED, {
            action_name='mount lifecycle verification',
            reason=reason,
            message=message,
            trace=mount_state and mount_state.probe_error or nil,
        })
    end
    if not module_environment_ok then
        local message = 'project module environment was not restored during ' ..
            reason
        table.insert(run.output_lines, 'CLEANUP_ERROR ' .. message)
        table.insert(run.failure_details, {
            kind='error',
            name='automation cleanup: project module environment',
            message=message,
        })
        publish_run_event(run, EventType.CLEANUP_FAILED, {
            action_name='project module environment',
            reason=reason,
            message=message,
        })
    end
    publish_run_event(run, EventType.CLEANUP_FINISHED, {
        cleanup_confirmed=run.cleanup_confirmed,
        mount_cleanup_verified=mount_ok,
    })
    return run.cleanup_confirmed
end

---Finalizes a run from Busted counts or an uncaught host failure.
---@param registry table
---@param run table
---@param ok boolean
---@param host_error any
local function finalize_run(registry, run, ok, host_error)
    if registry.active_run_id ~= run.run_id or
            registry.runs[run.run_id] ~= run or
            run.terminal then
        return
    end
    service.begin_cleanup(run.run_id, run.generation, 'suite completion',
        run.cleanup_module.pending_count(run.cleanup_registry),
        service_dependencies())
    if not ok then
        run.host_error = tostring(host_error)
        run.host_trace = debug.traceback(run.coroutine, tostring(host_error))
        run.counts.errors = run.counts.errors + 1
        run.totals.errors = run.totals.errors + 1
        table.insert(run.output_lines, 'HOST_ERROR ' .. run.host_error)
    end
    local cleanup_ok = clean_run(run, 'suite completion')
    if not cleanup_ok and not run.cleanup_failure_reported_by_busted then
        run.counts.errors = run.counts.errors + 1
        run.totals.errors = run.totals.errors + 1
    end
    run.finished_ms = dfhack.getTickCount()
    run.finished_frame = current_frame()
    local terminal_state
    if ok and cleanup_ok and run.totals.failures == 0 and
            run.totals.errors == 0 then
        terminal_state = RunState.PASSED
    else
        terminal_state = RunState.FAILED
    end
    service.complete_active(run.run_id, run.generation, terminal_state,
        cleanup_ok, run.cleanup_reason, service_dependencies())
    run.terminal_observed = false
    M.activate_next()
end

---Starts Busted execution when the queued generation still owns the run.
---@param package_root string
---@param project_root string
---@param registry table
---@param run table
local function begin_queued_run(package_root, project_root, registry, run)
    if registry.active_run_id ~= run.run_id or
            registry.runs[run.run_id] ~= run or
            run.state ~= RunState.STARTING then
        return
    end
    run.scheduled_timeout_id = nil
    service.start_active(run.run_id, run.generation, {
        repeat_count=run.options.repeat_count,
        options={
            seed=run.options.seed,
            shuffle=false,
            filters=run.options.filters,
            filter_out=run.options.filter_out,
            names=run.options.names,
            tags=run.options.tags,
            exclude_tags=run.options.exclude_tags,
        },
    }, service_dependencies())
    run.started_ms = dfhack.getTickCount()
    run.started_frame = current_frame()
    local scheduler_module = load_automation_module(package_root,
        'dwarfspec.automation.coroutine_scheduler',
        'src/dwarfspec/automation/coroutine_scheduler.lua')
    local scheduler
    scheduler = scheduler_module.new(run, {
        is_current=function()
            return registry.active_run_id == run.run_id and
                registry.runs[run.run_id] == run and
                run.state == RunState.RUNNING
        end,
        schedule_timeout=function(delay, callback)
            return dfhack.timeout(delay, 'frames', callback)
        end,
        cancel_timeout=cancel_timeout,
        now_ms=dfhack.getTickCount,
        diagnostics=current_diagnostics,
        on_complete=function(ok, host_error)
            finalize_run(registry, run, ok, host_error)
        end,
    })
    run.scheduler_module = scheduler_module
    run.scheduler = scheduler
    run.coroutine = coroutine.create(function()
        execute_suite(package_root, project_root, run, scheduler_module,
            scheduler)
    end)
    scheduler_module.bind(scheduler, run.coroutine)
    local ok, yielded = coroutine.resume(run.coroutine)
    if ok and coroutine.status(run.coroutine) ~= 'dead' then
        if not scheduler_module.owns_yield(scheduler, yielded) then
            finalize_run(registry, run, false,
                'automation suite yielded outside the owned scheduler')
            return
        end
        run.suspended = true
        return
    end
    finalize_run(registry, run, ok, yielded)
end


---Aborts a run for a host-owned reason and performs emergency cleanup.
---@param registry table
---@param run table
---@param reason string
---@return table
local function terminate_aborted(registry, run, reason)
    publish_run_event(run, EventType.RUN_ABORTED, {reason=reason})
    service.begin_cleanup(run.run_id, run.generation, reason,
        run.cleanup_module.pending_count(run.cleanup_registry),
        service_dependencies())
    local cleanup_ok = clean_run(run, reason)
    if not cleanup_ok and not run.cleanup_failure_reported_by_busted then
        run.counts.errors = run.counts.errors + 1
        run.totals.errors = run.totals.errors + 1
    end
    run.finished_ms = dfhack.getTickCount()
    run.finished_frame = current_frame()
    table.insert(run.output_lines, 'ABORTED ' .. reason)
    service.complete_active(run.run_id, run.generation, RunState.ABORTED,
        cleanup_ok, reason, service_dependencies())
    run.terminal_observed = false
    M.activate_next()
    return run
end

---Performs emergency cleanup for one exact lease-expired generation.
---@param run_id string
---@param generation integer
---@param reason string
---@return table
function M.expire_active(run_id, generation, reason)
    local registry = get_registry()
    assert(registry.active_run_id == run_id,
        'expired execution lease no longer owns the executor')
    local run = assert(registry.runs[run_id],
        'expired execution lease references an unknown run')
    assert(run.generation == generation,
        'expired execution lease generation does not match')
    return terminate_aborted(registry, run, reason)
end

---Initializes host-only runtime fields on one admitted service run.
---@param run table
---@param package_root string
---@param project_root string
---@param options table
local function initialize_runtime(run, package_root, project_root, options)
    local cleanup_module = load_automation_module(package_root,
        'dwarfspec.automation.cleanup',
        'src/dwarfspec/automation/cleanup.lua')
    local created_ms = dfhack.getTickCount()
    run.protocol_version = M.protocol_version
    run.package_root = package_root
    run.project_root = project_root
    run.options = options
    run.state_changed_ms = created_ms
    run.created_ms = created_ms
    run.created_frame = current_frame()
    run.started_ms = nil
    run.started_frame = nil
    run.finished_ms = nil
    run.finished_frame = nil
    run.last_status_poll_ms = nil
    run.last_status_poll_frame = nil
    run.current_test = nil
    run.output_lines = {}
    run.failure_details = {}
    run.discovered_files = {}
    run.coroutine = nil
    run.scheduled_timeout_id = nil
    run.outstanding_wait = nil
    run.cleanup_module = cleanup_module
    run.cleanup_registry = nil
    run.cleanup_reason = nil
    run.mount_cleanup_probe = nil
    run.mount_cleanup_state = nil
    run.module_environment_audit = nil
    run.recorded_cleanup_failures = {}
    run.cleanup_failure_reported_by_busted = false
    run.scheduler_module = nil
    run.scheduler = nil
    run.suspended = false
    run.terminal_observed = false
    assert(type(run.lease_check_frames) == 'number' and
        run.lease_check_frames >= 1 and run.lease_check_frames % 1 == 0,
        'lease check interval must be a positive integer')
    run.cleanup_registry = cleanup_module.new(run, function()
        local registry = dfhack.dwarfspec
        return type(registry) == 'table' and
            registry.active_run_id == run.run_id and
            registry.runs[run.run_id] == run and
            run.generation == registry.runs[run.run_id].generation and
            not run.terminal
    end)
    run.event_publisher = {
        now_ms=dfhack.getTickCount,
        publish=function(event_type, payload)
            return service.publish_active_event(run.run_id, run.generation,
                event_type, payload, service_dependencies())
        end,
    }
end

---Schedules native execution for one activated run.
---@param registry table
---@param run table
local function schedule_activated_run(registry, run)
    local timeout_id = dfhack.timeout(run.options.defer_frames, 'frames',
        function()
        begin_queued_run(run.package_root, run.project_root, registry, run)
    end)
    if not timeout_id then
        finalize_run(registry, run, false,
            'DFHack rejected the automation startup timer')
        return
    end
    run.scheduled_timeout_id = timeout_id
end

---Activates and schedules the next service-owned FIFO run when possible.
---@return table|nil
function M.activate_next()
    local outcome = service.activate_next(service_dependencies())
    if not outcome.activated then return nil end
    local registry = get_registry()
    local run = assert(registry.runs[outcome.identity.run_id],
        'activated service run is missing from the registry')
    schedule_activated_run(registry, run)
    return run
end

---Returns canonical service selection identities for host spec arguments.
---@param specs string[]|nil
---@return string[]
local function service_selection(specs)
    local identities = {}
    for _, spec in ipairs(specs or {}) do
        table.insert(identities, 'tests/' .. spec:gsub('\\', '/'))
    end
    table.sort(identities)
    return identities
end

---Starts one service-owned nonblocking automation run.
---@param package_root string
---@param project_root string
---@param options table
---@return table
function M.start(package_root, project_root, options)
    assert(dfhack.is_core_context,
        'live automation must run in DFHack core context')
    assert(type(package_root) == 'string' and package_root ~= '',
        'DwarfSpec package root must be a nonempty string')
    assert(type(project_root) == 'string' and project_root ~= '',
        'project root must be a nonempty string')
    validate_run_id(options.run_id)
    local dependencies = service_dependencies(options.run_id)
    service.bootstrap({
        protocol_version=M.service_protocol_version,
        package_root=package_root,
        package_version=M.package_version,
    }, dependencies)
    local scheduler = service.scheduler_snapshot(dependencies)
    if scheduler.quarantine.active then
        error({
            kind=SchedulerFailureKind.EXECUTOR_QUARANTINED,
            message='DwarfSpec executor is quarantined',
            blocking_run_id=scheduler.quarantine.run_id,
            blocking_generation=scheduler.quarantine.generation,
            reason=scheduler.quarantine.reason,
        }, 0)
    end
    local project = service.register_project({
        project_root=project_root,
        normalized_configuration=options,
        result_policy=options.result_policy or ResultPolicy.NONE,
        result_path=options.result_path,
        client_compatibility={
            protocol=M.service_protocol_version,
            package_version=M.package_version,
        },
    }, dependencies)
    local outcome = service.submit(project.project_id, {
        request_key='version1-request:' .. options.run_id,
        owner_kind=options.owner_kind or OwnerKind.EXTERNAL,
        queue_lease_ms=options.queue_lease_ms or
            options.lease_timeout_ms or 5000,
        execution_lease_ms=options.execution_lease_ms or
            options.lease_timeout_ms or 5000,
        lease_check_frames=options.lease_check_frames or 30,
        selection={identities=service_selection(options.specs)},
    }, dependencies)
    if not outcome.accepted then
        if outcome.snapshot.terminal then
            error(('automation run %s has an unobserved %s result')
                :format(outcome.identity.run_id, outcome.snapshot.state))
        end
        error(('automation run %s is already %s')
            :format(outcome.identity.run_id, outcome.snapshot.state))
    end
    local registry = get_registry()
    local run = assert(registry.runs[outcome.identity.run_id],
        'admitted service run is missing from the registry')
    if outcome.reused then return run end
    run.owner_capability = outcome.owner_capability
    initialize_runtime(run, registry.package_root,
        project.normalized_project_root, options)
    if not options.defer_activation then M.activate_next() end
    return run
end

---Returns any retained service run by exact identifier.
---@param run_id string
---@return table|nil
function M.find(run_id)
    local registry = get_registry()
    return registry.runs[run_id]
end

---Returns an exact capability-bound mutation identity for one run.
---@param run table
---@param owner_capability string
---@return table
local function owner_request(run, owner_capability)
    return {
        service_instance_id=run.service_instance_id,
        project_id=run.project_id,
        run_id=run.run_id,
        generation=run.generation,
        owner_capability=owner_capability,
    }
end

---Observes one retained run without renewing or transferring ownership.
---@param run_id string
---@return table
function M.observe(run_id)
    local run = M.find(run_id)
    if not run then error('automation run not found: ' .. run_id) end
    return run
end

---Renews an owned nonterminal run and returns its current state.
---@param run_id string
---@param owner_capability string
---@return table
function M.poll(run_id, owner_capability)
    local run = M.observe(run_id)
    assert(type(owner_capability) == 'string' and owner_capability ~= '',
        'status poll requires the owner capability')
    if not M.is_terminal(run) then
        service.renew(owner_request(run, owner_capability),
            service_dependencies())
        run.last_status_poll_ms = dfhack.getTickCount()
        run.last_status_poll_frame = current_frame()
    else
        run.terminal_observed = true
    end
    return run
end

---Returns canonical transport data after one event sequence cursor.
---@param run_id string
---@param after_sequence integer
---@return table
function M.transport(run_id, after_sequence)
    return service.transport(run_id, after_sequence, service_dependencies())
end

---Renews an owned run and returns canonical cursor-based transport data.
---@param run_id string
---@param owner_capability string
---@param after_sequence integer
---@return table
function M.poll_transport(run_id, owner_capability, after_sequence)
    M.poll(run_id, owner_capability)
    return M.transport(run_id, after_sequence)
end

---Acknowledges successful persistence for one exact terminal owner.
---@param run_id string
---@param generation integer
---@param owner_capability string
---@return table
function M.acknowledge(run_id, generation, owner_capability)
    local run = M.observe(run_id)
    local request = owner_request(run, owner_capability)
    request.generation = generation
    request.persistence = {
        succeeded=true,
        policy=run.result_policy,
        result_path=run.result_path,
    }
    service.acknowledge(request, service_dependencies())
    return run
end

---Cancels one exact capability-owned queued run.
---@param run_id string
---@param owner_capability string
---@param reason string|nil
---@return table
function M.cancel(run_id, owner_capability, reason)
    local run = M.observe(run_id)
    assert(run.state == RunState.QUEUED,
        'only a queued automation run can be cancelled')
    local request = owner_request(run, owner_capability)
    request.reason = reason or 'by request'
    service.cancel(request, service_dependencies())
    table.insert(run.output_lines, 'CANCELLED ' .. request.reason)
    run.terminal_observed = false
    return run
end

---Recovers one owned nonterminal run from its authoritative current state.
---@param run_id string
---@param owner_capability string
---@param reason string|nil
---@return table
function M.recover(run_id, owner_capability, reason)
    local run = M.observe(run_id)
    if M.is_terminal(run) then return run end
    if run.state == RunState.QUEUED then
        return M.cancel(run_id, owner_capability,
            reason or 'external runner recovery')
    end
    local request = owner_request(run, owner_capability)
    request.reason = reason or 'external runner recovery'
    service.abort(request, service_dependencies())
    return run
end

---Explicitly discards one exact terminal result through local authority.
---@param run_id string
---@param generation integer
---@param reason string
---@return table
function M.discard(run_id, generation, reason)
    local run = M.observe(run_id)
    service.discard({
        service_instance_id=run.service_instance_id,
        project_id=run.project_id,
        run_id=run.run_id,
        generation=generation,
        authority={local_dfhack_run=true},
        reason=reason,
    }, service_dependencies())
    return run
end

---Returns the current canonical scheduler snapshot.
---@return table
function M.scheduler_snapshot()
    return service.scheduler_snapshot(service_dependencies())
end

---Clears executor quarantine after authoritative live-state verification.
---@param run_id string
---@param generation integer
---@param reason string
---@return table
function M.recover_executor(run_id, generation, reason)
    local registry = get_registry()
    local outcome = service.recover_executor({
        service_instance_id=registry.service_instance_id,
        run_id=run_id,
        generation=generation,
        reason=reason,
        proof={local_dfhack_run=true},
    }, service_dependencies())
    M.activate_next()
    return outcome
end

---Aborts an owned queued or suspended run and invalidates its callbacks.
---@param run_id string
---@param owner_capability string|nil
---@return table
function M.abort(run_id, owner_capability)
    local registry = get_registry()
    local run = registry.runs[run_id]
    if not run then error('automation run not found: ' .. run_id) end
    if M.is_terminal(run) then return run end
    local reason = 'by request'
    if run.state == RunState.QUEUED then
        if owner_capability ~= nil then
            local request = owner_request(run, owner_capability)
            request.reason = reason
            service.cancel(request, service_dependencies())
        else
            service.operator_cancel({
                service_instance_id=run.service_instance_id,
                project_id=run.project_id,
                run_id=run.run_id,
                generation=run.generation,
                authority={local_dfhack_run=true},
                reason='local operator cancellation',
            }, service_dependencies())
        end
        table.insert(run.output_lines, 'CANCELLED ' .. reason)
        run.terminal_observed = false
        return run
    end
    assert(registry.active_run_id == run_id,
        'active automation run not found: ' .. run_id)
    if owner_capability ~= nil then
        local request = owner_request(run, owner_capability)
        request.reason = reason
        service.abort(request, service_dependencies())
        return run
    end
    service.operator_abort({
        service_instance_id=run.service_instance_id,
        project_id=run.project_id,
        run_id=run.run_id,
        generation=run.generation,
        authority={local_dfhack_run=true},
        reason='local operator abort',
    }, service_dependencies())
    return run
end

local JSON_NULL = '\0'

---Encodes one canonical transport response with DFHack JSON.
---@param transport table
---@return string
function M.encode_transport(transport)
    return require('json').encode(transport, {
        pretty=false,
        null=JSON_NULL,
    })
end

---Builds one JSON-safe machine-readable live automation report.
---@param run table
---@return table
function M.report_data(run)
    local failures = {}
    for _, detail in ipairs(run.failure_details) do
        table.insert(failures, {
            kind=detail.kind,
            name=detail.name,
            message=detail.message,
            trace=detail.trace or JSON_NULL,
        })
    end
    return {
        schema='dwarfspec.run.v1',
        protocol=run.protocol_version,
        service_instance_id=run.service_instance_id,
        project_id=run.project_id,
        run_id=run.run_id,
        state=run.state,
        terminal=M.is_terminal(run),
        generation=run.generation,
        project_root=run.project_root,
        selection=run.selection,
        submitted_at_ms=run.submitted_at_ms,
        activated_at_ms=run.activated_at_ms or JSON_NULL,
        finished_at_ms=run.finished_at_ms or JSON_NULL,
        queue_wait_ms=run.queue_wait_ms or JSON_NULL,
        events=run.event_journal and run.event_journal.events or {},
        counts=run.counts,
        totals=run.totals,
        current_test=run.current_test or JSON_NULL,
        output_count=#run.output_lines,
        cleanup_confirmed=run.cleanup_confirmed,
        cleanup_reason=run.cleanup_reason or JSON_NULL,
        mount_cleanup_state=run.mount_cleanup_state or JSON_NULL,
        host_error=run.host_error or JSON_NULL,
        host_trace=run.host_trace or JSON_NULL,
        failures=failures,
    }
end

---Encodes one complete machine-readable live automation report with DFHack JSON.
---@param run table
---@return string
function M.encode_report(run)
    return require('json').encode(M.report_data(run), {
        pretty=false,
        null=JSON_NULL,
    })
end

return M
