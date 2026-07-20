-- Safe programmatic Busted host for DFHack core-context automation.

local M = {
    protocol_version=1,
}

local TERMINAL_STATES = {
    passed=true,
    failed=true,
    aborted=true,
}

---Returns a repository path using the active platform separator.
---@param root string
---@param relative_path string
---@return string
local function join_path(root, relative_path)
    local separator = package.config:sub(1, 1)
    return root .. separator .. relative_path:gsub('[/\\]', separator)
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
    return TERMINAL_STATES[run.state] == true
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
---@param expected string|string[]
---@param target string
local function transition(run, expected, target)
    local allowed = type(expected) == 'table' and expected or {expected}
    for _, state in ipairs(allowed) do
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

---Configures pinned pure-Lua dependencies and DFHack-native adapters.
---@param package_root string
local function configure_dependencies(package_root)
    local separator = package.config:sub(1, 1)
    local lua_root = join_path(package_root, '.luarocks/share/lua/5.4')
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

    local system_adapter = assert(loadfile(join_path(package_root,
        'tests/automation/support/system_adapter.lua')))()
    local lfs_adapter = assert(loadfile(join_path(package_root,
        'tests/automation/support/lfs_adapter.lua')))()
    package.preload.system = function() return system_adapter end
    package.preload.lfs = function() return lfs_adapter end
    package.loaded.system = system_adapter
    package.loaded.lfs = lfs_adapter

    -- busted.init consumes its callable metatable during initialization.
    package.loaded.busted = nil
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
---@param spec string|nil
---@return table
function M.discover_tests(project_root, loader, spec)
    assert(type(project_root) == 'string' and project_root ~= '',
        'project root must be a nonempty string')
    assert(type(loader) == 'function', 'live spec discovery requires a loader')
    if spec then
        assert(type(spec) == 'string' and
            spec:match('^[%w_./-]+_spec%.ds%.lua$') and
            not spec:match('^[/\\]') and not spec:match('%.%.[/\\]'),
            'live spec must name one project-relative *_spec.ds.lua path')
    end
    local roots
    if spec then
        roots = {join_path(project_root, 'tests/' .. spec)}
    else
        roots = {join_path(project_root, 'tests')}
    end
    return loader(roots, {'_spec%.ds%.lua$'}, {
        excludes={},
        recursive=true,
        verbose=false,
    })
end

---Installs run-scoped cleanup around every discovered Busted example.
---@param busted table
---@param ds table
function M.install_ds_lifecycle(busted, ds)
    assert(type(busted) == 'table' and type(busted.api) == 'table',
        'Busted root API is required for automation lifecycle hooks')
    assert(type(busted.api.before_each) == 'function' and
        type(busted.api.after_each) == 'function',
        'Busted before_each and after_each APIs are required')
    assert(type(ds) == 'table' and type(ds.reset) == 'function',
        'automation ds.reset is required for lifecycle hooks')
    busted.api.before_each(function()
        ds.reset()
    end)
    busted.api.after_each(function()
        ds.reset()
    end)
end

---Executes one configured Busted suite synchronously inside its owner coroutine.
---@param repo_root string
---@param run table
---@param scheduler_module table
---@param scheduler table
local function execute_suite(package_root, project_root, run, scheduler_module,
        scheduler)
    configure_dependencies(package_root)
    local busted = require('busted.core')()
    require('busted')(busted)
    local project_module = assert(loadfile(join_path(package_root,
        'tests/automation/support/project.lua')))()
    local project = project_module.new(project_root, package_root,
        dfhack.filesystem)
    local extensions_module = assert(loadfile(join_path(package_root,
        'tests/automation/support/extensions.lua')))()
    local extensions = extensions_module.load(project)
    local ds_factory = assert(loadfile(join_path(package_root,
        'tests/automation/support/ds.lua')))()
    local ds = ds_factory.new(package_root, project, scheduler_module,
        scheduler, run.cleanup_module, run.cleanup_registry, extensions)
    busted.export('ds', ds)
    M.install_ds_lifecycle(busted, ds)

    local output_factory = assert(loadfile(join_path(package_root,
        'tests/automation/support/output_handler.lua')))()
    output_factory.new(busted, run)
    require('busted.modules.filter_loader')()(busted,
        M.filter_options(run.options))

    local loader = require('busted.modules.test_file_loader')(
        busted, {'lua'})
    run.discovered_files = M.discover_tests(project_root, loader,
        run.options.spec)

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
    local ok, failures = run.cleanup_module.run(run.cleanup_registry, reason)
    run.coroutine = nil
    run.suspended = false
    run.cleanup_confirmed = ok and
        run.cleanup_module.pending_count(run.cleanup_registry) == 0 and
        run.outstanding_wait == nil and run.coroutine == nil and
        run.scheduler == nil and run.scheduled_timeout_id == nil and
        run.lease_timeout_id == nil
    run.cleanup_reason = reason
    if not ok then record_cleanup_failures(run, failures) end
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
    transition(run, 'running', 'cleaning')
    if not ok then
        run.host_error = tostring(host_error)
        run.host_trace = debug.traceback(run.coroutine, tostring(host_error))
        run.counts.errors = run.counts.errors + 1
        run.totals.errors = run.totals.errors + 1
        table.insert(run.output_lines, 'HOST_ERROR ' .. run.host_error)
    end
    local cleanup_ok = clean_run(run, 'suite completion')
    if not cleanup_ok then
        run.counts.errors = run.counts.errors + 1
        run.totals.errors = run.totals.errors + 1
    end
    run.finished_ms = dfhack.getTickCount()
    run.finished_frame = current_frame()
    if ok and cleanup_ok and run.totals.failures == 0 and
            run.totals.errors == 0 then
        transition(run, 'cleaning', 'passed')
    else
        transition(run, 'cleaning', 'failed')
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
            run.state ~= 'starting' then
        return
    end
    run.scheduled_timeout_id = nil
    transition(run, 'starting', 'running')
    run.started_ms = dfhack.getTickCount()
    run.started_frame = current_frame()
    local scheduler_module = assert(loadfile(join_path(package_root,
        'tests/automation/support/scheduler.lua')))()
    local scheduler
    scheduler = scheduler_module.new(run, {
        is_current=function()
            return registry.active_run == run and
                registry.generation == run.generation and
                run.state == 'running'
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
    transition(run, {'starting', 'running'}, 'cleaning')
    clean_run(run, reason)
    run.finished_ms = dfhack.getTickCount()
    run.finished_frame = current_frame()
    table.insert(run.output_lines, 'ABORTED ' .. reason)
    transition(run, 'cleaning', 'aborted')
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
    local cleanup_module = assert(loadfile(join_path(package_root,
        'tests/automation/support/cleanup.lua')))()
    local created_ms = dfhack.getTickCount()
    local run = {
        protocol_version=M.protocol_version,
        run_id=options.run_id,
        generation=registry.generation,
        state='starting',
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
