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
    dfhack.dwarfui = dfhack.dwarfui or {}
    local registry = dfhack.dwarfui.automation
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
        dfhack.dwarfui.automation = registry
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
---@param repo_root string
local function configure_dependencies(repo_root)
    local separator = package.config:sub(1, 1)
    local lua_root = join_path(repo_root, '.luarocks/share/lua/5.4')
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

    local system_adapter = assert(loadfile(join_path(repo_root,
        'Tests/Automation/support/system_adapter.lua')))()
    local lfs_adapter = assert(loadfile(join_path(repo_root,
        'Tests/Automation/support/lfs_adapter.lua')))()
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
local function filter_options(options)
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

---Executes one configured Busted suite synchronously inside its owner coroutine.
---@param repo_root string
---@param run table
local function execute_suite(repo_root, run)
    configure_dependencies(repo_root)
    local busted = require('busted.core')()
    require('busted')(busted)
    local dy = assert(loadfile(join_path(repo_root,
        'Tests/Automation/support/dy.lua')))()
    busted.export('dy', dy)

    local output_factory = assert(loadfile(join_path(repo_root,
        'Tests/Automation/support/output_handler.lua')))()
    output_factory.new(busted, run)
    require('busted.modules.filter_loader')()(busted,
        filter_options(run.options))

    local loader = require('busted.modules.test_file_loader')(
        busted, {'lua'})
    local roots
    if run.options.spec then
        roots = {join_path(repo_root,
            'Tests/Automation/specs/' .. run.options.spec)}
    else
        roots = {join_path(repo_root, 'Tests/Automation/specs')}
    end
    run.discovered_files = loader(roots, {'_live_spec%.lua$'}, {
        excludes={},
        recursive=true,
        verbose=false,
    })

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
    run.finished_ms = dfhack.getTickCount()
    run.finished_frame = current_frame()
    if ok and run.totals.failures == 0 and run.totals.errors == 0 then
        transition(run, 'cleaning', 'passed')
    else
        transition(run, 'cleaning', 'failed')
    end
    run.coroutine = nil
    run.scheduled_timeout_id = nil
    archive_run(registry, run)
end

---Starts Busted execution when the queued generation still owns the run.
---@param repo_root string
---@param registry table
---@param run table
local function begin_queued_run(repo_root, registry, run)
    if registry.active_run ~= run or registry.generation ~= run.generation or
            run.state ~= 'starting' then
        return
    end
    run.scheduled_timeout_id = nil
    transition(run, 'starting', 'running')
    run.started_ms = dfhack.getTickCount()
    run.started_frame = current_frame()
    run.coroutine = coroutine.create(function()
        execute_suite(repo_root, run)
    end)
    local ok, host_error = coroutine.resume(run.coroutine)
    if ok and coroutine.status(run.coroutine) ~= 'dead' then
        run.suspended = true
        return
    end
    finalize_run(registry, run, ok, host_error)
end

---Starts one uniquely owned nonblocking automation run.
---@param repo_root string
---@param options table
---@return table
function M.start(repo_root, options)
    assert(dfhack.is_core_context,
        'live automation must run in DFHack core context')
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
    local run = {
        protocol_version=M.protocol_version,
        run_id=options.run_id,
        generation=registry.generation,
        state='starting',
        state_changed_ms=dfhack.getTickCount(),
        created_ms=dfhack.getTickCount(),
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
        outstanding_wait=nil,
        cleanup_registry={},
        suspended=false,
        terminal_observed=false,
    }
    registry.active_run = run
    local timeout_id = dfhack.timeout(options.defer_frames, 'frames', function()
        begin_queued_run(repo_root, registry, run)
    end)
    if not timeout_id then
        registry.active_run = nil
        error('DFHack rejected the automation startup timer')
    end
    run.scheduled_timeout_id = timeout_id
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

    registry.generation = registry.generation + 1
    if run.scheduled_timeout_id then
        dfhack.timeout_active(run.scheduled_timeout_id, nil)
        run.scheduled_timeout_id = nil
    end
    transition(run, {'starting', 'running'}, 'cleaning')
    run.coroutine = nil
    run.suspended = false
    run.finished_ms = dfhack.getTickCount()
    run.finished_frame = current_frame()
    table.insert(run.output_lines, 'ABORTED by request')
    transition(run, 'cleaning', 'aborted')
    archive_run(registry, run)
    return run
end

return M
