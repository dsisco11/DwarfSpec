-- Service-owned Busted host for DFHack core-context automation.

local RunState = require('dwarfspec.protocol.enums.run_states')
local EventType = require('dwarfspec.protocol.enums.event_types')
local events = require('dwarfspec.protocol.events')
local focus_diagnostics =
    require('dwarfspec.protocol.diagnostics.focus')
local focus_warning =
    require('dwarfspec.protocol.diagnostics.focus_warning')
local OwnerKind = require('dwarfspec.protocol.enums.owner_kinds')
local ResultPolicy = require('dwarfspec.protocol.enums.result_policies')
local SchedulerFailureKind =
    require('dwarfspec.protocol.enums.scheduler_failure_kinds')
local adapter_errors = require('dwarfspec.protocol.adapter_errors')
local service = require('dwarfspec.host.service.service')
local module_environment_module =
    require('dwarfspec.host.environment.module_environment')
local suite_discovery_module =
    require('dwarfspec.host.execution.suite_discovery')
local transport_publication =
    require('dwarfspec.host.execution.transport_publication')
local run_assembly = require('dwarfspec.host.execution.run_assembly')
local run_capabilities_module =
    require('dwarfspec.host.execution.run_capabilities')
local recurring_operation_adapter_module =
    require('dwarfspec.host.execution.recurring_operation_adapter')
local example_lifecycle_module = require('dwarfspec.host.execution.example_lifecycle')
local suite_executor_module = require('dwarfspec.host.execution.suite_executor')
local run_lifecycle_module = require('dwarfspec.host.execution.run_lifecycle')

local M = {
    protocol_version=2,
    package_version='0.2.2',
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
---@return table
local function load_automation_module(package_root, module_name)
    local source_path = join_path(package_root,
        'src/' .. module_name:gsub('%.', '/') .. '.lua')
    local source_file = io.open(source_path, 'rb')
    if source_file then
        source_file:close()
        return assert(loadfile(source_path))()
    end
    local ok, module = pcall(require, module_name)
    if ok then return module end
    error(module, 0)
end

local suite_discovery = suite_discovery_module.new(join_path)

local module_environment = module_environment_module.new({
    clear_dependencies=M.clear_dependency_modules,
    load_module=load_automation_module,
})

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
---@param operation string|nil
---@return table
local function get_registry(operation)
    local registry = dfhack.dwarfspec
    if operation and (type(registry) ~= 'table' or
            registry.protocol_version ~= M.protocol_version or
            registry.schema ~= service.schema) then
        error(adapter_errors.domain('service_not_loaded',
            'The compatible DwarfSpec service is not loaded.',
            {operation=operation}), 0)
    end
    assert(type(registry) == 'table' and
        registry.protocol_version == M.protocol_version and
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
    if run.unit_speed_cleanup_probe ~= nil then
        return false, 'quarantined unit speed cleanup probe remains active'
    end
    local mount = run.mount_cleanup_state
    if mount and (mount.current_mount_id ~= nil or
            mount.active_screen_count ~= 0 or
            (mount.tracked_screen_count or 0) ~= 0 or
            (mount.owned_screen_count or 0) ~= 0 or
            (mount.borrowed_native_screen_count or 0) ~= 0 or
            (mount.native_screen_dismissal_count or 0) ~= 0 or
            mount.subject_count ~= 0 or
            mount.pointer_active == true or
            mount.button_state_active == true or
            mount.game_pause_state_active == true or
            mount.game_speed_active == true or
            mount.render_observer_active == true or
            mount.verified ~= true) then
        return false, 'quarantined mount state is not clean'
    end
    local modules = run.module_environment_audit
    if modules and (modules.restored ~= true or
            modules.path_restored ~= true) then
        return false, 'quarantined project module environment is not restored'
    end
    local unit_speed = run.unit_speed_cleanup_state
    if unit_speed and (unit_speed.unit_speed_active == true or
            unit_speed.callback_scheduled == true or
            unit_speed.ownership_active == true or
            (unit_speed.retained_id_count or 0) ~= 0 or
            unit_speed.verified ~= true) then
        return false, 'quarantined unit speed state is not clean'
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

---Configures pinned Lua dependencies and DFHack-native adapters.
---@param package_root string
---@param configured_lua_root string|nil
---@return string[]
local function configure_dependencies(package_root, configured_lua_root)
    return module_environment.configure(package_root, configured_lua_root)
end

---Installs project-root module lookup and returns cleanup plus an audit record.
---@param project_root string
---@param protected_entries string[]
---@param runtime_package table|nil
---@return function, table
function M.configure_project_modules(project_root, protected_entries,
        runtime_package)
    return module_environment.configure_project(project_root, protected_entries,
        runtime_package)
end

---Creates the standard Busted filter options for one automation run.
---@param options table
---@return table
function M.filter_options(options)
    return suite_discovery.filter_options(options)
end

---Discovers only DwarfSpec live-spec files from the selected project root.
---@param project_root string
---@param loader function
---@param specs string[]|nil
---@return table
function M.discover_tests(project_root, loader, specs)
    return suite_discovery.discover(project_root, loader, specs)
end

---Creates per-example and file-suite focus observations and diagnostics.
---@param run table
---@param reset function
---@param guard BaseScreenFocusGuard
---@return table
function M.new_focus_lifecycle(run, reset, guard)
    return example_lifecycle_module.new(run, reset, guard, {
        copy_json=events.copy_json,
        event_type=EventType.DIAGNOSTIC_RECORDED,
        change_kind=focus_diagnostics.CHANGE_KIND,
        format_warning=focus_warning.format_warning,
    })
end

---Installs internal entry handling before project example setup.
---@param lifecycle_adapter table
---@param busted table
---@param lifecycle table
function M.install_ds_example_entry(lifecycle_adapter, busted, lifecycle)
    return example_lifecycle_module.install_entry(
        lifecycle_adapter, busted, lifecycle)
end

---Installs internal exit handling after all project example teardown.
---@param lifecycle_adapter table
---@param busted table
---@param lifecycle table
function M.install_ds_example_exit(lifecycle_adapter, busted, lifecycle)
    return example_lifecycle_module.install_exit(
        lifecycle_adapter, busted, lifecycle)
end

---Executes one configured Busted suite synchronously inside its owner coroutine.
---@param repo_root string
---@param run table
---@param scheduler_module table
---@param scheduler table
local function execute_suite(package_root, project_root, run, scheduler_module,
        scheduler)
    ---Creates the native overlay services injected into this run.
    ---@return table
    local function create_overlay_services()
        return load_automation_module(package_root,
            'dwarfspec.host.game.overlay_services').new()
    end

    return suite_executor_module.execute(package_root, project_root, run,
        scheduler_module, scheduler, {
            configure_dependencies=configure_dependencies,
            configure_project=M.configure_project_modules,
            load_module=load_automation_module,
            filesystem=dfhack.filesystem,
            gui=dfhack.gui,
            ds_factory=run.ds_factory,
            new_run_capabilities=run_capabilities_module.new,
            create_overlay_services=create_overlay_services,
            create_recurring_operations=function(active_run)
                return recurring_operation_adapter_module.new({
                    schedule_tick=function(delay, callback)
                        return dfhack.timeout(delay, 'ticks', callback)
                    end,
                    cancel_timeout=function(handle)
                        return dfhack.timeout_active(handle, nil)
                    end,
                    timeout_active=function(handle)
                        return dfhack.timeout_active(handle)
                    end,
                    is_run_active=function()
                        local registry = dfhack.dwarfspec
                        return type(registry) == 'table' and
                            registry.active_run_id == active_run.run_id and
                            registry.runs[active_run.run_id] == active_run and
                            not active_run.terminal
                    end,
                    report_failure=function(message, trace)
                        active_run.counts.errors =
                            active_run.counts.errors + 1
                        active_run.totals.errors =
                            active_run.totals.errors + 1
                        table.insert(active_run.output_lines,
                            'HOST_ERROR ' .. message)
                        table.insert(active_run.failure_details, {
                            kind='error',
                            name='unit speed recurring operation',
                            message=message,
                            trace=trace or message,
                        })
                    end,
                })
            end,
            new_lifecycle=M.new_focus_lifecycle,
            install_entry=M.install_ds_example_entry,
            install_exit=M.install_ds_example_exit,
            filter_options=M.filter_options,
            discover_tests=M.discover_tests,
            new_busted=function()
                local busted = require('busted.core')()
                require('busted')(busted)
                return busted
            end,
            install_filter=function(busted, options)
                require('busted.modules.filter_loader')()(busted, options)
            end,
            new_loader=function(busted)
                return require('busted.modules.test_file_loader')(
                    busted, {'lua'})
            end,
            execute_busted=function(busted, repeat_count, options)
                return require('busted.execute')(busted)(
                    repeat_count, options)
            end,
        })
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
    return transport_publication.publish(run, event_type, payload)
end

local clean_run
local finalize_run
local begin_queued_run

local run_lifecycle = run_lifecycle_module.new({
    states={
        starting=RunState.STARTING,
        running=RunState.RUNNING,
        passed=RunState.PASSED,
        failed=RunState.FAILED,
        aborted=RunState.ABORTED,
    },
    events={
        cleanup_failed=EventType.CLEANUP_FAILED,
        cleanup_finished=EventType.CLEANUP_FINISHED,
        run_aborted=EventType.RUN_ABORTED,
    },
    publish_event=publish_run_event,
    begin_cleanup=function(run, reason)
        return service.begin_cleanup(run.run_id, run.generation, reason,
            run.cleanup_module.pending_count(run.cleanup_registry),
            service_dependencies())
    end,
    complete_active=function(run, state, cleanup_ok, reason)
        return service.complete_active(run.run_id, run.generation, state,
            cleanup_ok, reason, service_dependencies())
    end,
    start_active=function(run)
        return service.start_active(run.run_id, run.generation, {
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
    end,
    activate_next=function() return M.activate_next() end,
    cancel_timeout=cancel_timeout,
    now_ms=function() return dfhack.getTickCount() end,
    current_frame=current_frame,
    assemble_scheduler=function(package_root, run, callbacks)
        return run_assembly.create_scheduler(package_root, run, {
            load_scheduler=function(root)
                return load_automation_module(root,
                    'dwarfspec.host.execution.coroutine_scheduler')
            end,
            is_current=callbacks.is_current,
            schedule_frames=function(delay, callback)
                return dfhack.timeout(delay, 'frames', callback)
            end,
            schedule_ticks=function(delay, callback)
                return dfhack.timeout(delay, 'ticks', callback)
            end,
            cancel_timeout=cancel_timeout,
            now_ms=function() return dfhack.getTickCount() end,
            diagnostics=current_diagnostics,
            on_complete=callbacks.on_complete,
        })
    end,
    execute_suite=execute_suite,
})

clean_run = run_lifecycle.clean
finalize_run = run_lifecycle.finalize
begin_queued_run = run_lifecycle.begin


---Aborts a run for a host-owned reason and performs emergency cleanup.
---@param registry table
---@param run table
---@param reason string
---@return table
local function terminate_aborted(registry, run, reason)
    return run_lifecycle.abort(registry, run, reason)
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
    local ds_factory = load_automation_module(package_root, 'dwarfspec.ds')
    return run_assembly.initialize(run, package_root, project_root, options, {
        load_module=load_automation_module,
        now_ms=dfhack.getTickCount,
        current_frame=current_frame,
        ds_factory=ds_factory,
        create_event_publisher=transport_publication.new_publisher,
        is_active=function()
            local registry = dfhack.dwarfspec
            return type(registry) == 'table' and registry.active_run_id == run.run_id and
                registry.runs[run.run_id] == run and run.generation == registry.runs[run.run_id].generation and not run.terminal
        end,
        publish_active_event=function(run_id, generation, event_type, payload)
            return service.publish_active_event(run_id, generation, event_type, payload, service_dependencies())
        end,
    })
end

---Schedules native execution for one activated run.
---@param registry table
---@param run table
local function schedule_activated_run(registry, run)
    return run_assembly.schedule_activation(run, {
        schedule_frames=function(delay, callback)
            return dfhack.timeout(delay, 'frames', callback)
        end,
        begin_run=function()
            begin_queued_run(run.package_root, run.project_root, registry, run)
        end,
        fail_run=function(message)
            finalize_run(registry, run, false, message)
        end,
    })
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

local ADMISSION_MESSAGES = {
    [SchedulerFailureKind.PROJECT_BUSY]=
        'This project already has an outstanding DwarfSpec run.',
    [SchedulerFailureKind.REQUEST_KEY_CONFLICT]=
        'This request identity is already bound to a different DwarfSpec run.',
    [SchedulerFailureKind.RESULT_PATH_BUSY]=
        'The configured result destination is reserved by another DwarfSpec run.',
}

---Constructs a public structured rejection for one expected admission conflict.
---@param outcome table
---@return table
local function admission_rejection(outcome)
    local message = ADMISSION_MESSAGES[outcome.kind]
    if not message then return nil end
    return adapter_errors.domain(outcome.kind, message, {
        blocking_run_id=outcome.identity.run_id,
        blocking_generation=outcome.identity.generation,
        state=outcome.snapshot.state,
        reason=outcome.reason,
    })
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
        protocol_version=M.protocol_version,
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
            protocol=M.protocol_version,
            package_version=M.package_version,
        },
    }, dependencies)
    local outcome = service.submit(project.project_id, {
        request_key='run-request:' .. options.run_id,
        owner_kind=options.owner_kind or OwnerKind.EXTERNAL,
        queue_lease_ms=options.queue_lease_ms or
            options.lease_timeout_ms or 5000,
        execution_lease_ms=options.execution_lease_ms or
            options.lease_timeout_ms or 5000,
        lease_check_frames=options.lease_check_frames or 30,
        selection={identities=service_selection(options.specs)},
    }, dependencies)
    if not outcome.accepted then
        local rejection = admission_rejection(outcome)
        if rejection then error(rejection, 0) end
        error(outcome.reason or 'DwarfSpec scheduler rejected the run', 0)
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
---@param operation string|nil
---@return table|nil
function M.find(run_id, operation)
    local registry = get_registry(operation)
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
---@param operation string|nil
---@return table
function M.observe(run_id, operation)
    operation = operation or 'observe'
    local run = M.find(run_id, operation)
    if not run then
        error(adapter_errors.domain('run_not_found',
            'DwarfSpec run was not found.',
            {operation=operation, run_id=run_id}), 0)
    end
    return run
end

---Validates expected polling identity and cursor before any lease mutation.
---@param run table
---@param operation string
---@param after_sequence integer|nil
---@param expected_generation integer|nil
local function validate_transport_request(run, operation, after_sequence,
        expected_generation)
    if expected_generation ~= nil and
            expected_generation ~= run.generation then
        error(adapter_errors.domain('generation_mismatch',
            'The requested run generation is stale.', {
                operation=operation, run_id=run.run_id,
                generation=expected_generation,
                current_generation=run.generation,
            }), 0)
    end
    if after_sequence == nil then return end
    assert(type(after_sequence) == 'number' and after_sequence >= 0 and
        after_sequence % 1 == 0,
        'event cursor must be a nonnegative integer')
    events.validate_journal(run.event_journal)
    local last_sequence = #run.event_journal.events
    if after_sequence > last_sequence then
        error(adapter_errors.domain('event_cursor_ahead',
            'The requested event cursor is ahead of the retained journal.', {
                operation=operation, run_id=run.run_id,
                generation=run.generation, state=run.state,
                after_sequence=after_sequence,
                last_sequence=last_sequence,
            }), 0)
    end
end

---Renews an owned nonterminal run and returns its current state.
---@param run_id string
---@param owner_capability string
---@param expected_generation integer|nil
---@return table
function M.poll(run_id, owner_capability, expected_generation)
    local run = M.observe(run_id, 'status poll')
    validate_transport_request(run, 'status poll', nil, expected_generation)
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
---@param operation string|nil
---@param expected_generation integer|nil
---@return table
function M.transport(run_id, after_sequence, operation, expected_generation)
    local label = operation or 'event read'
    local run = M.observe(run_id, label)
    validate_transport_request(run, label, after_sequence, expected_generation)
    return service.transport(run_id, after_sequence, service_dependencies())
end

---Renews an owned run and returns canonical cursor-based transport data.
---@param run_id string
---@param owner_capability string
---@param after_sequence integer
---@param expected_generation integer|nil
---@return table
function M.poll_transport(run_id, owner_capability, after_sequence,
        expected_generation)
    local run = M.observe(run_id, 'status poll')
    validate_transport_request(run, 'status poll', after_sequence,
        expected_generation)
    M.poll(run_id, owner_capability, expected_generation)
    return service.transport(run_id, after_sequence, service_dependencies())
end

---Acknowledges successful persistence for one exact terminal owner.
---@param run_id string
---@param generation integer
---@param owner_capability string
---@return table
function M.acknowledge(run_id, generation, owner_capability)
    local run = M.observe(run_id, 'acknowledgement')
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
    local run = M.observe(run_id, 'cancel')
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
    local run = M.observe(run_id, 'recover')
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
    local run = M.observe(run_id, 'discard')
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

---Returns immutable summaries for every retained service run.
---@return table[]
function M.run_history()
    return service.run_history(service_dependencies())
end

---Returns an immutable full inspection of one retained service run.
---@param run_id string
---@return table
function M.run_inspection(run_id)
    local transport = M.transport(run_id, 0)
    local registry = get_registry()
    local project = registry.projects[transport.project_id]
    return {
        snapshot=transport.snapshot,
        events=transport.events,
        last_sequence=transport.last_sequence,
        project_name=project and project.display_name or nil,
        project_root=project and project.normalized_project_root or nil,
    }
end

---Returns immutable captured output for one retained service run.
---@param run_id string
---@return table
function M.run_logs(run_id)
    return service.run_logs(run_id, service_dependencies())
end

---Clears executor quarantine after authoritative live-state verification.
---@param run_id string
---@param generation integer
---@param reason string
---@return table
function M.recover_executor(run_id, generation, reason)
    local registry = get_registry('recover executor')
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
    local registry = get_registry('abort')
    local run = registry.runs[run_id]
    if not run then
        error(adapter_errors.domain('run_not_found',
            'DwarfSpec run was not found.',
            {operation='abort', run_id=run_id}), 0)
    end
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
    return transport_publication.encode(transport, JSON_NULL)
end

return M
