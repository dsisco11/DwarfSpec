-- External DwarfSpec orchestration over the supported dfhack-run bridge.

local process = require('dwarfspec.process')
local project = require('dwarfspec.project')
local reports = require('dwarfspec.report')
local ResultPolicy = require('dwarfspec.automation.result_policies')
local ResultState = require('dwarfspec.automation.result_states')
local result_store = require('dwarfspec.automation.result_store')
local RunState = require('dwarfspec.automation.run_states')
local RunnerFailureKind = require('dwarfspec.runner_failure_kinds')

local M = {}

local exit_codes = {
    [RunnerFailureKind.SUCCESS]=0,
    [RunnerFailureKind.USAGE]=2,
    [RunnerFailureKind.DEPENDENCY]=3,
    [RunnerFailureKind.CONNECTION]=4,
    [RunnerFailureKind.REGISTRATION]=5,
    [RunnerFailureKind.HOST]=5,
    [RunnerFailureKind.TEST]=6,
    [RunnerFailureKind.TIMEOUT]=7,
    [RunnerFailureKind.QUEUE_TIMEOUT]=7,
    [RunnerFailureKind.ABORTED]=8,
    [RunnerFailureKind.CANCELLED]=8,
}

---Rejects mutation of the compatibility exit-code view.
---@param target table
---@param key any
local function reject_exit_code_mutation(target, key)
    error('DwarfSpec runner exit codes are immutable: ' .. tostring(key), 2)
end

---Returns one compatibility exit code by serialized failure kind.
---@param target table
---@param key any
---@return integer|nil
local function exit_code_index(target, key)
    return exit_codes[key]
end

---Iterates the compatibility exit-code view.
---@return function, table, nil
local function exit_code_pairs()
    return next, exit_codes, nil
end

M.failure_kinds = RunnerFailureKind
M.exit_codes = setmetatable({}, {
    __index=exit_code_index,
    __metatable='DwarfSpec runner exit codes',
    __newindex=reject_exit_code_mutation,
    __pairs=exit_code_pairs,
})

---Creates one classified runner failure.
---@param kind DwarfSpecRunnerFailureKind
---@param message string
---@return table
local function failure(kind, message)
    assert(exit_codes[kind] ~= nil,
        'runner failure kind must be a RunnerFailureKind')
    return {
        kind=kind,
        message=message,
        exit_code=exit_codes[kind],
    }
end

---Raises one classified runner failure.
---@param kind DwarfSpecRunnerFailureKind
---@param message string
local function fail(kind, message)
    error(failure(kind, message), 0)
end

---Removes an incidental Lua source location from a user-facing error.
---@param value any
---@return string
local function clean_message(value)
    return tostring(value):gsub('^.-:%d+: ', '')
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

---Returns one installed or source-tree host entry script path.
---@param options table
---@param name string
---@return string
local function host_script(options, name)
    local scripts = options.host_scripts or {}
    if scripts[name] then return scripts[name] end
    return project.join(options.package_root,
        'tests/automation/support/' .. name .. '.lua')
end

---Resolves the shared Lua module root for source and installed layouts.
---@param package_root string
---@return string
local function lua_module_root(package_root)
    if is_file(project.join(package_root, 'busted/core.lua')) then
        return package_root
    end
    local lua_version = assert(_VERSION:match('Lua (%d+%.%d+)'),
        'could not determine the active Lua version from ' .. tostring(_VERSION))
    return project.join(package_root,
        '.luarocks/share/lua/' .. lua_version)
end

---Validates pure-Lua dependencies required by the in-process host.
---@param options table
local function validate_dependencies(options)
    local lua_root = lua_module_root(options.package_root)
    for _, path in ipairs({
            project.join(lua_root, 'busted/core.lua'),
            project.join(lua_root, 'busted/init.lua'),
            project.join(lua_root, 'luassert/init.lua'),
            host_script(options, 'bootstrap'),
            host_script(options, 'status'),
            host_script(options, 'recover'),
            host_script(options, 'abort'),
            host_script(options, 'acknowledge'),
            host_script(options, 'probe')}) do
        if not is_file(path) then
            fail(RunnerFailureKind.DEPENDENCY,
                'DwarfSpec dependency was not found: ' .. path)
        end
    end
end

---Appends one repeated bootstrap option for every caller value.
---@param arguments string[]
---@param name string
---@param values string[]|nil
local function append_values(arguments, name, values)
    for _, value in ipairs(values or {}) do
        table.insert(arguments, '--' .. name .. '=' .. value)
    end
end

---Builds in-process bootstrap arguments for one selected run.
---@param options table
---@param run_id string
---@return string[]
local function bootstrap_arguments(options, run_id)
    local result_policy = options.result_path and
        ResultPolicy.FILE or ResultPolicy.NONE
    local arguments = {
        'lua', '-f', host_script(options, 'bootstrap'),
        run_id,
        '--project-root=' .. options.project_root,
        '--repeat=' .. tostring(options.repeat_count),
        '--defer-frames=' .. tostring(options.startup_delay_frames),
        '--lease-timeout-ms=' .. tostring(options.lease_timeout_ms),
        '--lease-check-frames=' .. tostring(options.lease_check_frames),
        '--test-glob=' .. tostring(options.test_glob or '*.ds.lua'),
        '--lua-module-root=' .. lua_module_root(options.package_root),
        '--result-policy=' .. result_policy,
    }
    if options.result_path then
        table.insert(arguments, '--result-path=' .. options.result_path)
    end
    append_values(arguments, 'filter', options.filters)
    append_values(arguments, 'filter-out', options.filter_out)
    append_values(arguments, 'name', options.names)
    append_values(arguments, 'tag', options.tags)
    append_values(arguments, 'exclude-tag', options.exclude_tags)
    for _, identity in ipairs(options.identities) do
        table.insert(arguments, '--spec=' .. project.host_spec(identity))
    end
    return arguments
end

---Verifies a healthy DFHack core context before starting a run.
---@param runner string
---@param options table
---@param invoke function
local function verify_connection(runner, options, invoke)
    local ok, result = pcall(invoke, runner, {
        'lua', '-f', host_script(options, 'probe'),
    })
    if not ok then
        fail(RunnerFailureKind.CONNECTION,
            'could not contact DFHack through ' .. runner .. ': ' ..
                clean_message(result))
    end
    if result.exit_code ~= 0 or
            result.lines[#result.lines] ~=
                'DWARFSPEC_PROBE protocol=1 core=true timeout=function' then
        fail(RunnerFailureKind.CONNECTION,
            'DFHack is not running or did not provide a healthy core Lua ' ..
                'context')
    end
end

---Returns an externally unique and host-safe run identifier.
---@param now number
---@return string
local function generate_run_id(now)
    local random = math.random(0, 0x7fffffff)
    return ('dwarfspec-%d-%08x'):format(math.floor(now * 1000), random)
end

---Returns one UTC timestamp for a persisted state transition.
---@param options table
---@return string
local function timestamp(options)
    if options.timestamp then return options.timestamp() end
    return os.date('!%Y-%m-%dT%H:%M:%SZ')
end

---Maps a classified runner failure to its persisted invocation state.
---@param runner_error table
---@param native_report table|nil
---@param interrupted boolean
---@return DwarfSpecResultState
local function failure_result_state(runner_error, native_report, interrupted)
    if interrupted then return ResultState.INTERRUPTED end
    if runner_error.kind == RunnerFailureKind.DEPENDENCY then
        return ResultState.DEPENDENCY_ERROR
    elseif runner_error.kind == RunnerFailureKind.CONNECTION then
        return ResultState.CONNECTION_ERROR
    elseif runner_error.kind == RunnerFailureKind.QUEUE_TIMEOUT then
        return ResultState.QUEUE_TIMEOUT
    elseif runner_error.kind == RunnerFailureKind.TIMEOUT then
        return ResultState.TIMEOUT
    elseif runner_error.kind == RunnerFailureKind.REGISTRATION then
        return ResultState.REGISTRATION_ERROR
    elseif runner_error.kind == RunnerFailureKind.ABORTED and
            native_report and native_report.state == RunState.ABORTED then
        return ResultState.ABORTED
    elseif runner_error.kind == RunnerFailureKind.CANCELLED then
        return ResultState.CANCELLED
    elseif runner_error.kind == RunnerFailureKind.TEST and native_report then
        if native_report.state == RunState.PASSED then
            return ResultState.FAILED
        end
        return native_report.state
    end
    return ResultState.HOST_ERROR
end

---Adds actionable guidance to one host registration rejection.
---@param message string
---@return string
local function registration_message(message)
    local result = 'DwarfSpec bootstrap rejected: ' .. message
    if message:match('incompatible automation package version') then
        result = result .. '. Restart DFHack to unload the running ' ..
            'DwarfSpec service before using a different package version'
    end
    return result
end

---Returns whether a native report has entered the executor.
---@param report table
---@return boolean
local function entered_executor(report)
    return report.state ~= RunState.QUEUED and
        report.activated_at_ms ~= nil
end

---Constructs one persisted invocation view from current runner state.
---@param options table
---@param native_report table|nil
---@param state DwarfSpecResultState
---@param terminal boolean
---@param exit_code integer|nil
---@param submitted_at string
---@param activated_at string|nil
---@param finished_at string|nil
---@param runner_error table|nil
---@param journal table[]|nil
---@return table
local function invocation_result(options, native_report, state, terminal,
        exit_code, submitted_at, activated_at, finished_at, runner_error,
        journal)
    local identity = native_report and native_report.service_instance_id ~= nil
    return result_store.build({
        service_instance_id=identity and
            native_report.service_instance_id or nil,
        project_id=identity and native_report.project_id or nil,
        run_id=identity and native_report.run_id or nil,
        generation=identity and native_report.generation or nil,
        state=state,
        terminal=terminal,
        exit_code=exit_code,
        project_root=project.normalize(options.project_root),
        selection={identities=options.identities},
        submitted_at=submitted_at,
        activated_at=activated_at,
        finished_at=finished_at,
        queue_wait_ms=native_report and native_report.queue_wait_ms or nil,
        error=runner_error and {
            kind=runner_error.kind,
            message=runner_error.message,
        } or nil,
        host_report=native_report and entered_executor(native_report) and
            native_report or nil,
        events=journal or {},
    })
end

---Validates and optionally replaces the configured latest-result file.
---@param options table
---@param result table
local function persist_result(options, result)
    if not options.result_path then return end
    local store = options.result_store or result_store
    store.write(options.result_path, result, {
        filesystem=options.filesystem,
        open_file=options.open_result_file,
        remove_file=options.remove_result_file,
        replace_file=options.replace_result_file,
        encode=options.encode_result,
    })
end

---Attempts state-aware recovery without replacing the original failure.
---@param runner string
---@param options table
---@param run_id string
---@param owner_capability string|nil
---@param expected table|nil
---@param after_sequence integer
---@param invoke function
---@return table|nil, string|nil, string|nil
local function recover_run(runner, options, run_id, owner_capability,
        expected, after_sequence, invoke)
    local script = owner_capability and 'recover' or 'abort'
    local arguments = {
        'lua', '-f', host_script(options, script), run_id,
    }
    if owner_capability ~= nil then
        table.insert(arguments, owner_capability)
        table.insert(arguments, tostring(after_sequence))
        table.insert(arguments, 'external runner recovery')
    else
        table.insert(arguments, '')
        table.insert(arguments, tostring(after_sequence))
    end
    local invoked, result = pcall(invoke, runner, arguments)
    if not invoked then
        return nil, 'recovery bridge failed: ' .. clean_message(result), nil
    end
    if result.exit_code ~= 0 then
        return nil, 'recovery exited with ' .. result.exit_code, nil
    end
    local parse_expected = {}
    for name, value in pairs(expected or {run_id=run_id}) do
        parse_expected[name] = value
    end
    parse_expected.after_sequence = after_sequence
    local ok, transport, payload = pcall(reports.parse_transport,
        result.lines, parse_expected, options.decode_json)
    local report = ok and transport.snapshot or transport
    if not ok then return nil, tostring(report), nil end
    if not report.terminal then
        return transport, 'recovery left the run nonterminal', payload
    end
    if report.state == RunState.ABORTED and
            not report.cleanup_confirmed then
        return transport, 'recovery abort did not confirm cleanup', payload
    end
    if report.state ~= RunState.CANCELLED and
            not report.cleanup_confirmed then
        return transport, 'recovery terminal cleanup was not confirmed',
            payload
    end
    return transport, nil, payload
end

---Acknowledges one persisted terminal generation through its owner capability.
---@param runner string
---@param options table
---@param run_id string
---@param generation integer
---@param owner_capability string
---@param expected table
---@param after_sequence integer
---@param invoke function
local function acknowledge_terminal(runner, options, run_id, generation,
        owner_capability, expected, after_sequence, invoke)
    local result = invoke(runner, {
        'lua', '-f', host_script(options, 'acknowledge'),
        run_id, tostring(generation), owner_capability,
        tostring(after_sequence),
    })
    assert(result.exit_code == 0,
        'DwarfSpec acknowledgement exited with ' .. result.exit_code)
    local parse_expected = {}
    for name, value in pairs(expected) do parse_expected[name] = value end
    parse_expected.after_sequence = after_sequence
    reports.parse_transport(result.lines, parse_expected,
        options.decode_json)
end

---Runs selected live specifications and returns a stable command outcome.
---@param options table
---@return table
function M.run(options)
    local system = options.system or require('system')
    local invoke = options.invoke or process.invoke
    local emit = options.emit or print
    local now = options.now or system.monotime
    local sleep = options.sleep or system.sleep
    local command_started_at = now()
    local submitted_at = timestamp(options)
    local run_id = options.run_id or generate_run_id(command_started_at)
    local configured_policy = options.result_policy or
        (options.result_path == false and ResultPolicy.NONE or
            ResultPolicy.FILE)
    options.result_policy = configured_policy
    options.result_path = configured_policy == ResultPolicy.FILE and
        result_store.resolve_path(options.project_root, options.result_path,
            options.filesystem) or nil
    local runner
    local native_report
    local persisted_result
    local owner_capability
    local runner_error
    local bootstrap_attempted = false
    local bootstrap_rejected = false
    local interrupted = false
    local activated_at
    local expected_identity
    local event_cursor = 0
    local event_journal = {}
    local queue_started_at
    local execution_started_at

    ---Persists one observed native state before continuing orchestration.
    ---@param report table
    local function persist_observation(report)
        if activated_at == nil and entered_executor(report) then
            activated_at = timestamp(options)
            execution_started_at = now()
        end
        local observed = invocation_result(options, report, report.state,
            report.terminal, report.terminal and
                (report.state == RunState.PASSED and
                    exit_codes[RunnerFailureKind.SUCCESS] or
                    exit_codes[RunnerFailureKind.TEST]) or nil,
            submitted_at, activated_at,
            report.terminal and timestamp(options) or nil, nil,
            event_journal)
        persist_result(options, observed)
        persisted_result = observed
    end

    ---Consumes one validated transport response in cursor order.
    ---@param transport table
    ---@param persist boolean
    local function consume_transport(transport, persist)
        for _, event in ipairs(transport.events) do
            table.insert(event_journal, event)
        end
        event_cursor = transport.last_sequence
        native_report = transport.snapshot
        if activated_at == nil and entered_executor(native_report) then
            activated_at = timestamp(options)
            execution_started_at = now()
        end
        for _, line in ipairs(reports.format_events(transport.events)) do
            emit(line)
        end
        if persist then persist_observation(native_report) end
    end

    ---Returns a copy of the exact transport identity with one cursor.
    ---@param after_sequence integer
    ---@return table
    local function transport_expectation(after_sequence)
        local expected = {run_id=run_id, after_sequence=after_sequence}
        if expected_identity then
            for name, value in pairs(expected_identity) do
                expected[name] = value
            end
        end
        return expected
    end

    ---Submits idempotently and tolerates one ambiguous bridge response.
    ---@return table
    local function bootstrap_transport()
        local arguments = bootstrap_arguments(options, run_id)
        local last_error
        queue_started_at = now()
        for attempt = 1, 2 do
            local invoked, start = pcall(invoke, runner, arguments)
            if invoked and start.exit_code ~= 0 then
                fail(RunnerFailureKind.REGISTRATION,
                    'DwarfSpec bootstrap exited with ' .. start.exit_code)
            end
            if invoked then
                local parsed, transport, capability, response_error =
                    pcall(function()
                        local response, _, adapter_error =
                            reports.parse_transport_response(start.lines,
                                transport_expectation(0),
                                options.decode_json)
                        if adapter_error then
                            return nil, nil, adapter_error
                        end
                        return response,
                            reports.owner_capability(start.lines), nil
                end)
                if parsed then
                    if response_error then
                        bootstrap_rejected = true
                        fail(RunnerFailureKind.REGISTRATION,
                            registration_message(response_error.message))
                    end
                    owner_capability = capability
                    return transport
                end
                last_error = transport
            else
                last_error = start
            end
            if attempt == 1 and options.verbose then
                emit('DwarfSpec bootstrap response was ambiguous; ' ..
                    'retrying the same request')
            end
        end
        fail(RunnerFailureKind.REGISTRATION,
            'DwarfSpec bootstrap response was invalid: ' ..
                clean_message(last_error))
    end

    local ok, caught = xpcall(function()
        validate_dependencies(options)
        local resolved, resolve_error
        resolved, runner = pcall(process.resolve_runner, options,
            options.environment)
        if not resolved then
            resolve_error = runner
            runner = nil
            fail(RunnerFailureKind.DEPENDENCY,
                clean_message(resolve_error))
        end
        if options.verbose then emit('DFHack runner: ' .. runner) end
        verify_connection(runner, options, invoke)

        bootstrap_attempted = true
        local initial = bootstrap_transport()
        expected_identity = {
            service_instance_id=initial.service_instance_id,
            project_id=initial.project_id,
            run_id=initial.run_id,
            generation=initial.generation,
        }
        consume_transport(initial, true)

        while not native_report.terminal do
            local current_time = now()
            if native_report.state == RunState.QUEUED and
                    options.queue_timeout_seconds ~= nil and
                    current_time - queue_started_at >=
                        options.queue_timeout_seconds then
                fail(RunnerFailureKind.QUEUE_TIMEOUT,
                    ('DwarfSpec queue wait timed out after %s seconds')
                        :format(options.queue_timeout_seconds))
            end
            if execution_started_at ~= nil and
                    current_time - execution_started_at >=
                        options.timeout_seconds then
                fail(RunnerFailureKind.TIMEOUT,
                    ('DwarfSpec execution timed out after %s seconds')
                        :format(options.timeout_seconds))
            end
            sleep(options.poll_interval_ms / 1000)
            local status = invoke(runner, {
                'lua', '-f', host_script(options, 'status'),
                run_id, owner_capability, tostring(event_cursor),
            })
            if status.exit_code ~= 0 then
                fail(RunnerFailureKind.HOST,
                    'DwarfSpec status exited with ' .. status.exit_code)
            end
            local transport = reports.parse_transport(status.lines,
                transport_expectation(event_cursor), options.decode_json)
            consume_transport(transport, true)
        end

        local native_state = native_report.state
        if native_state == RunState.ABORTED then
            fail(RunnerFailureKind.ABORTED, 'DwarfSpec run was aborted')
        end
        if native_state == RunState.CANCELLED then
            fail(RunnerFailureKind.CANCELLED,
                'DwarfSpec run was cancelled before activation')
        end
        if native_state ~= RunState.PASSED then
            fail(RunnerFailureKind.TEST,
                'DwarfSpec run finished with state ' ..
                    tostring(native_report.state))
        end
        if not native_report.cleanup_confirmed then
            fail(RunnerFailureKind.TEST,
                'DwarfSpec run passed without confirmed cleanup')
        end
    end, function(value) return value end)

    if not ok then
        if type(caught) == 'table' and caught.exit_code then
            runner_error = caught
        elseif clean_message(caught):lower():match('interrupt') then
            interrupted = true
            runner_error = failure(RunnerFailureKind.ABORTED,
                'DwarfSpec run interrupted')
        else
            runner_error = failure(RunnerFailureKind.HOST,
                clean_message(caught))
        end
        if runner and bootstrap_attempted and
                not bootstrap_rejected and
                (not native_report or not native_report.terminal) then
            local recovered, recovery_error = recover_run(
                runner, options, run_id, owner_capability,
                expected_identity, event_cursor, invoke)
            if recovered then
                consume_transport(recovered, false)
            end
            if recovery_error then
                runner_error.message = runner_error.message ..
                    '; recovery failed: ' .. recovery_error
            end
        end
    end

    local final_exit_code = runner_error and runner_error.exit_code or
        exit_codes[RunnerFailureKind.SUCCESS]
    local final_state = runner_error and failure_result_state(
        runner_error, native_report, interrupted) or
        native_report.state
    local final_result = invocation_result(options, native_report,
        final_state, true, final_exit_code, submitted_at, activated_at,
        timestamp(options), runner_error, event_journal)
    local write_ok, write_error = pcall(persist_result, options, final_result)
    if write_ok then
        persisted_result = final_result
    else
        local persistence_message = 'could not write result report: ' ..
            tostring(write_error)
        if runner_error then
            persistence_message = runner_error.message .. '; ' ..
                persistence_message
        end
        runner_error = failure(RunnerFailureKind.HOST,
            persistence_message)
        persisted_result = invocation_result(options, native_report,
            ResultState.PERSISTENCE_ERROR, true, runner_error.exit_code,
            submitted_at, activated_at, timestamp(options), runner_error,
            event_journal)
    end

    if write_ok and native_report and native_report.terminal and
            owner_capability ~= nil then
        local acknowledge_ok, acknowledge_error = pcall(
            acknowledge_terminal, runner, options, run_id,
            native_report.generation, owner_capability, expected_identity,
            event_cursor, invoke)
        if not acknowledge_ok and not runner_error then
            runner_error = failure(RunnerFailureKind.HOST,
                tostring(acknowledge_error))
        elseif not acknowledge_ok then
            runner_error.message = runner_error.message ..
                '; could not acknowledge terminal result: ' ..
                    tostring(acknowledge_error)
        end
    end

    return {
        exit_code=runner_error and runner_error.exit_code or
            exit_codes[RunnerFailureKind.SUCCESS],
        run_id=run_id,
        runner=runner,
        report=native_report,
        result=persisted_result,
        result_path=options.result_path,
        error=runner_error,
    }
end

---Explicitly aborts one active run and requires confirmed cleanup.
---@param options table
---@param run_id string
---@return table
function M.abort(options, run_id)
    local invoke = options.invoke or process.invoke
    local ok, runner = pcall(process.resolve_runner, options,
        options.environment)
    if not ok then
        return {exit_code=exit_codes[RunnerFailureKind.DEPENDENCY],
            error=failure(RunnerFailureKind.DEPENDENCY,
                clean_message(runner))}
    end
    if options.verbose and options.emit then
        options.emit('DFHack runner: ' .. runner)
    end
    local connected, connection_error = pcall(verify_connection, runner,
        options, invoke)
    if not connected then
        local detail = type(connection_error) == 'table' and
            connection_error or
            failure(RunnerFailureKind.CONNECTION,
                clean_message(connection_error))
        return {exit_code=detail.exit_code, error=detail}
    end
    local result = invoke(runner, {
        'lua', '-f', host_script(options, 'abort'), run_id,
    })
    if result.exit_code ~= 0 then
        return {exit_code=exit_codes[RunnerFailureKind.HOST],
            error=failure(RunnerFailureKind.HOST,
                'DwarfSpec abort exited with ' .. result.exit_code)}
    end
    local ok, transport = pcall(reports.parse_transport, result.lines, {
        run_id=run_id,
        after_sequence=0,
    }, options.decode_json)
    if not ok then
        return {exit_code=exit_codes[RunnerFailureKind.HOST],
            error=failure(RunnerFailureKind.HOST, tostring(transport))}
    end
    local report = transport.snapshot
    if report.state == RunState.CANCELLED then
        return {exit_code=exit_codes[RunnerFailureKind.SUCCESS],
            report=report, events=transport.events}
    end
    if report.state ~= RunState.ABORTED or not report.cleanup_confirmed then
        return {exit_code=exit_codes[RunnerFailureKind.TEST], report=report,
            error=failure(RunnerFailureKind.TEST,
                'abort did not confirm cleanup')}
    end
    return {exit_code=exit_codes[RunnerFailureKind.SUCCESS], report=report,
        events=transport.events}
end

return M
