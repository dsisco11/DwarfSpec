-- Safe programmatic Busted host for DFHack core-context automation.

local RunState = require('dwarfspec.automation.run_states')

local M = {
    protocol_version=1,
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

---Returns the compatible process-wide automation registry.
---@return table
local function get_registry()
    local registry = dfhack.dwarfspec
    if registry and registry.protocol_version ~= M.protocol_version then
        error(('incompatible automation host protocol: expected %d, found %s')
            :format(M.protocol_version, tostring(registry.protocol_version)))
    end
    if not registry then
        registry = {
            protocol_version=M.protocol_version,
            generation=0,
            active_run=nil,
            last_completed=nil,
        }
        dfhack.dwarfspec = registry
    end
    return registry
end

---Moves a run through one explicitly permitted state transition.
---@param run table
---@param expected DwarfSpecRunState|DwarfSpecRunState[]
---@param target DwarfSpecRunState
local function transition(run, expected, target)
    assert(RUN_STATE_TERMINAL[target] ~= nil,
        'transition target must be a RunState')
    local allowed = type(expected) == 'string' and {expected} or expected
    assert(type(allowed) == 'table',
        'transition source must be a RunState or RunState array')
    for _, state in ipairs(allowed) do
        assert(RUN_STATE_TERMINAL[state] ~= nil,
            'transition source must be a RunState')
        if run.state == state then
            run.state = target
            run.state_changed_ms = dfhack.getTickCount()
            return
        end
    end
    error(('invalid automation state transition %s -> %s')
        :format(tostring(run.state), target))
end

---Archives a terminal run while retaining only the most recent completion.
---@param registry table
---@param run table
local function archive_run(registry, run)
    if registry.active_run == run then registry.active_run = nil end
    run.terminal_observed = false
    registry.last_completed = run
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

---Installs project-root module lookup and returns its idempotent cleanup.
---@param project_root string
---@param protected_entries string[]
---@param runtime_package table|nil
---@return function
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
            end
        end
        runtime_package.path = original_path
    end
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
    local restore_project_modules = M.configure_project_modules(project_root,
        dependency_entries)
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

---Records cleanup failures as host errors without hiding later failures.
---@param run table
---@param failures table[]
local function record_cleanup_failures(run, failures)
    for _, failure in ipairs(failures) do
        local failure_key = failure.id or failure
        if not run.recorded_cleanup_failures[failure_key] then
            run.recorded_cleanup_failures[failure_key] = true
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
    cancel_timeout(run.lease_timeout_id)
    run.lease_timeout_id = nil
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
    local history_ok = #run.cleanup_registry.failures == 0
    run.cleanup_confirmed = ok and history_ok and mount_ok and
        run.cleanup_module.pending_count(run.cleanup_registry) == 0 and
        run.outstanding_wait == nil and run.coroutine == nil and
        run.scheduler == nil and run.scheduled_timeout_id == nil and
        run.lease_timeout_id == nil
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
    end
    return run.cleanup_confirmed
end

---Finalizes a run from Busted counts or an uncaught host failure.
---@param registry table
---@param run table
---@param ok boolean
---@param host_error any
local function finalize_run(registry, run, ok, host_error)
    if registry.active_run ~= run or registry.generation ~= run.generation then
        return
    end
    transition(run, RunState.RUNNING, RunState.CLEANING)
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
    if ok and cleanup_ok and run.totals.failures == 0 and
            run.totals.errors == 0 then
        transition(run, RunState.CLEANING, RunState.PASSED)
    else
        transition(run, RunState.CLEANING, RunState.FAILED)
    end
    archive_run(registry, run)
end

---Starts Busted execution when the queued generation still owns the run.
---@param package_root string
---@param project_root string
---@param registry table
---@param run table
local function begin_queued_run(package_root, project_root, registry, run)
    if registry.active_run ~= run or registry.generation ~= run.generation or
            run.state ~= RunState.STARTING then
        return
    end
    run.scheduled_timeout_id = nil
    transition(run, RunState.STARTING, RunState.RUNNING)
    run.started_ms = dfhack.getTickCount()
    run.started_frame = current_frame()
    local scheduler_module = load_automation_module(package_root,
        'dwarfspec.automation.scheduler',
        'tests/automation/support/scheduler.lua')
    local scheduler
    scheduler = scheduler_module.new(run, {
        is_current=function()
            return registry.active_run == run and
                registry.generation == run.generation and
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
    registry.generation = registry.generation + 1
    transition(run, {RunState.STARTING, RunState.RUNNING},
        RunState.CLEANING)
    local cleanup_ok = clean_run(run, reason)
    if not cleanup_ok and not run.cleanup_failure_reported_by_busted then
        run.counts.errors = run.counts.errors + 1
        run.totals.errors = run.totals.errors + 1
    end
    run.finished_ms = dfhack.getTickCount()
    run.finished_frame = current_frame()
    table.insert(run.output_lines, 'ABORTED ' .. reason)
    transition(run, RunState.CLEANING, RunState.ABORTED)
    archive_run(registry, run)
    return run
end

---Schedules the next frame-based lease ownership check.
---@param registry table
---@param run table
local function schedule_lease_check(registry, run)
    local timeout_id
    timeout_id = dfhack.timeout(run.lease_check_frames, 'frames', function()
        if registry.active_run ~= run or
                registry.generation ~= run.generation or
                M.is_terminal(run) then
            return
        end
        if run.lease_timeout_id ~= timeout_id then return end
        run.lease_timeout_id = nil
        local last_poll_ms = run.last_status_poll_ms or run.created_ms
        run.lease_elapsed_ms = dfhack.getTickCount() - last_poll_ms
        if run.lease_elapsed_ms >= run.lease_timeout_ms then
            terminate_aborted(registry, run,
                ('status lease expired after %d ms'):format(
                    run.lease_elapsed_ms))
            return
        end
        schedule_lease_check(registry, run)
    end)
    if timeout_id == nil then
        error('DFHack rejected the automation lease timer')
    end
    run.lease_timeout_id = timeout_id
end

---Starts one uniquely owned nonblocking automation run.
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
    local registry = get_registry()
    if registry.active_run and not M.is_terminal(registry.active_run) then
        error(('automation run %s is already %s')
            :format(registry.active_run.run_id, registry.active_run.state))
    end
    if registry.last_completed and
            registry.last_completed.terminal_observed ~= true then
        error(('automation run %s has an unobserved %s result')
            :format(registry.last_completed.run_id,
                registry.last_completed.state))
    end

    registry.generation = registry.generation + 1
    local cleanup_module = load_automation_module(package_root,
        'dwarfspec.automation.cleanup',
        'tests/automation/support/cleanup.lua')
    local created_ms = dfhack.getTickCount()
    local run = {
        protocol_version=M.protocol_version,
        run_id=options.run_id,
        generation=registry.generation,
        state=RunState.STARTING,
        state_changed_ms=created_ms,
        created_ms=created_ms,
        created_frame=current_frame(),
        started_ms=nil,
        started_frame=nil,
        finished_ms=nil,
        finished_frame=nil,
        last_status_poll_ms=nil,
        last_status_poll_frame=nil,
        options=options,
        counts={successes=0, failures=0, errors=0, pending=0},
        totals={successes=0, failures=0, errors=0, pending=0},
        current_test=nil,
        output_lines={},
        failure_details={},
        discovered_files={},
        coroutine=nil,
        scheduled_timeout_id=nil,
        lease_timeout_id=nil,
        lease_timeout_ms=options.lease_timeout_ms or 5000,
        lease_check_frames=options.lease_check_frames or 30,
        lease_elapsed_ms=0,
        outstanding_wait=nil,
        cleanup_module=cleanup_module,
        cleanup_registry=nil,
        cleanup_confirmed=false,
        cleanup_reason=nil,
        mount_cleanup_probe=nil,
        mount_cleanup_state=nil,
        recorded_cleanup_failures={},
        cleanup_failure_reported_by_busted=false,
        scheduler_module=nil,
        scheduler=nil,
        suspended=false,
        terminal_observed=false,
    }
    assert(type(run.lease_timeout_ms) == 'number' and
        run.lease_timeout_ms >= 1,
        'lease timeout must be positive')
    assert(type(run.lease_check_frames) == 'number' and
        run.lease_check_frames >= 1 and run.lease_check_frames % 1 == 0,
        'lease check interval must be a positive integer')
    run.cleanup_registry = cleanup_module.new(run)
    registry.active_run = run
    local timeout_id = dfhack.timeout(options.defer_frames, 'frames', function()
        begin_queued_run(package_root, project_root, registry, run)
    end)
    if not timeout_id then
        registry.active_run = nil
        error('DFHack rejected the automation startup timer')
    end
    run.scheduled_timeout_id = timeout_id
    local lease_ok, lease_error = pcall(schedule_lease_check, registry, run)
    if not lease_ok then
        cancel_timeout(run.scheduled_timeout_id)
        run.scheduled_timeout_id = nil
        registry.active_run = nil
        error(lease_error)
    end
    return run
end

---Returns an active or most-recent completed run by exact id.
---@param run_id string
---@return table|nil
function M.find(run_id)
    local registry = get_registry()
    if registry.active_run and registry.active_run.run_id == run_id then
        return registry.active_run
    end
    if registry.last_completed and registry.last_completed.run_id == run_id then
        return registry.last_completed
    end
    return nil
end

---Records a status poll that renews an active run's frame-driven lease.
---@param run_id string
---@return table
function M.poll(run_id)
    local run = M.find(run_id)
    if not run then error('automation run not found: ' .. run_id) end
    run.last_status_poll_ms = dfhack.getTickCount()
    run.last_status_poll_frame = current_frame()
    if M.is_terminal(run) then run.terminal_observed = true end
    return run
end

---Aborts an owned queued or suspended run and invalidates its callbacks.
---@param run_id string
---@return table
function M.abort(run_id)
    local registry = get_registry()
    local run = registry.active_run
    if not run or run.run_id ~= run_id then
        error('active automation run not found: ' .. run_id)
    end
    if M.is_terminal(run) then return run end

    return terminate_aborted(registry, run, 'by request')
end

local JSON_NULL = '\0'

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
        run_id=run.run_id,
        state=run.state,
        terminal=M.is_terminal(run),
        generation=run.generation,
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
