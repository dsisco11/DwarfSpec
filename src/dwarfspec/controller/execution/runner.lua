-- External DwarfSpec orchestration over the supported dfhack-run bridge.

local command_builder_module = require('dwarfspec.controller.execution.command_builder')
local transport_client_module = require('dwarfspec.controller.execution.transport_client')
local run_poller_module = require('dwarfspec.controller.execution.run_poller')
local run_recovery_module = require('dwarfspec.controller.execution.run_recovery')
local result_interpreter_module = require('dwarfspec.controller.execution.result_interpreter')
local ErrorFormat = require('dwarfspec.protocol.configuration.error_formats')
local ResultPolicy = require('dwarfspec.protocol.enums.result_policies')
local RunnerFailureKind = require('dwarfspec.protocol.enums.runner_failure_kinds')

local M = {}

local exit_codes = {
    [RunnerFailureKind.SUCCESS]=0,
    [RunnerFailureKind.USAGE]=2,
    [RunnerFailureKind.DEPENDENCY]=3,
    [RunnerFailureKind.CONNECTION]=4,
    [RunnerFailureKind.REGISTRATION]=5,
    [RunnerFailureKind.EXECUTOR_QUARANTINED]=5,
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

local builder = command_builder_module.new({
    fail=fail,
    dependency_kind=RunnerFailureKind.DEPENDENCY,
})
local client = transport_client_module.new({
    builder=builder,
    failure=failure,
    failure_kinds=RunnerFailureKind,
    clean_message=clean_message,
})
local interpreter = result_interpreter_module.new({
    failure_kinds=RunnerFailureKind,
    exit_codes=exit_codes,
})
local poller = run_poller_module.new({
    builder=builder,
    client=client,
    fail=fail,
    failure_kinds=RunnerFailureKind,
    clean_message=clean_message,
    format_events=client.event_formatter(),
})
local recovery = run_recovery_module.new({
    builder=builder,
    client=client,
    failure=failure,
    failure_kinds=RunnerFailureKind,
    exit_codes=exit_codes,
    clean_message=clean_message,
})

---Formats one validated host registration rejection.
---@param rejection table
---@return string
local function registration_message(rejection)
    if rejection.code == 'package_version_mismatch' then
        return ('DwarfSpec could not start because DFHack already has a ' ..
            'different DwarfSpec version loaded.\n\n' ..
            '  Running DFHack service: %s\n' ..
            '  Current DwarfSpec command: %s\n\n' ..
            'To use %s, save and fully exit Dwarf Fortress/DFHack, ' ..
            'relaunch it,\nand retry this command. Returning to the title ' ..
            'screen or unloading the\nworld will not unload the process-wide ' ..
            'DwarfSpec service.'):format(rejection.running_version,
                rejection.requested_version, rejection.requested_version)
    end
    return 'DwarfSpec bootstrap rejected: ' .. rejection.message
end


---Runs selected live specifications and returns a stable command outcome.
---@param options table
---@return table
function M.run(options)
    local system = options.system or require('system')
    local emit = options.emit or print
    local now = options.now or system.monotime
    local sleep = options.sleep or system.sleep
    local error_format = options.error_format or ErrorFormat.MSBUILD
    local command_started_at = now()
    local submitted_at = timestamp(options)
    local run_id = options.run_id or generate_run_id(command_started_at)
    local configured_policy = options.result_policy or
        (options.result_path == false and ResultPolicy.NONE or
            ResultPolicy.FILE)
    options.result_policy = configured_policy
    options.result_path = configured_policy == ResultPolicy.FILE and
        interpreter.resolve_path(options.project_root, options.result_path,
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
    local diagnostic_formatting_failed = false

    ---Persists one observed native state before continuing orchestration.
    ---@param report table
    local function persist_observation(report)
        if activated_at == nil and interpreter.entered_executor(report) then
            activated_at = timestamp(options)
            execution_started_at = now()
        end
        local observed = interpreter.build(options, report, report.state,
            report.terminal, report.terminal and
                interpreter.native_exit_code(report) or nil,
            submitted_at, activated_at,
            report.terminal and timestamp(options) or nil, nil,
            event_journal)
        interpreter.persist(options, observed)
        persisted_result = observed
    end

    ---Consumes one validated transport response in cursor order.
    ---@param transport table
    ---@param persist boolean
    ---@param render boolean|nil
    local function consume_transport(transport, persist, render)
        local consumed = poller.consume({
            options=options, journal=event_journal,
            execution_started_at=execution_started_at,
            activated_at=function() return activated_at end,
            entered_executor=interpreter.entered_executor,
            activate=function()
                activated_at = timestamp(options)
                execution_started_at = now()
                return execution_started_at
            end,
            now=now, error_format=error_format, emit=emit,
            observe=function(report, cursor, execution_started)
                native_report = report
                event_cursor = cursor
                execution_started_at = execution_started
            end,
            formatting_failed=function() diagnostic_formatting_failed=true end,
            persist=persist_observation,
        }, transport, persist, render)
        event_cursor = consumed.cursor
        native_report = consumed.report
        execution_started_at = consumed.execution_started_at
        return consumed
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
        local arguments = builder.bootstrap(options, run_id)
        local last_error
        queue_started_at = now()
        for attempt = 1, 2 do
            local invoked, transport, capability, response_error = pcall(
                client.bootstrap_response,
                options, runner, arguments, transport_expectation(0))
            if invoked then
                if response_error then
                    bootstrap_rejected = true
                    local message = response_error.kind ==
                        RunnerFailureKind.REGISTRATION and
                        registration_message(response_error) or
                        response_error.message
                    fail(response_error.kind, message)
                end
                owner_capability = capability
                return transport
            else
                if type(transport) == 'table' and
                        transport.invalid_adapter_error then
                    bootstrap_rejected = true
                    fail(RunnerFailureKind.REGISTRATION,
                        'DwarfSpec bootstrap response was invalid: ' ..
                            clean_message(transport.message))
                end
                if type(transport) == 'table' and transport.exit_code and
                        not transport.retryable then
                    error(transport, 0)
                end
                last_error = type(transport) == 'table' and
                    transport.message or transport
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
        builder.validate_dependencies(options)
        local resolve_error
        runner, resolve_error = client.resolve(options)
        if not runner then error(resolve_error, 0) end
        if options.verbose then emit('DFHack runner: ' .. runner) end
        client.verify_connection(options, runner)

        bootstrap_attempted = true
        local initial = bootstrap_transport()
        expected_identity = {
            service_instance_id=initial.service_instance_id,
            project_id=initial.project_id,
            run_id=initial.run_id,
            generation=initial.generation,
        }
        consume_transport(initial, true)

        local polled = poller.until_terminal({
            options=options, runner=runner, run_id=run_id,
            owner_capability=owner_capability, report=native_report,
            cursor=event_cursor, queue_started_at=queue_started_at,
            execution_started_at=execution_started_at, now=now, sleep=sleep,
            expectation=transport_expectation, journal=event_journal,
            activated_at=function() return activated_at end,
            entered_executor=interpreter.entered_executor,
            activate=function()
                activated_at = timestamp(options)
                execution_started_at = now()
                return execution_started_at
            end,
            error_format=error_format, emit=emit,
            observe=function(report, cursor, execution_started)
                native_report = report
                event_cursor = cursor
                execution_started_at = execution_started
            end,
            formatting_failed=function() diagnostic_formatting_failed=true end,
            persist=persist_observation,
        })
        native_report = polled.report
        event_cursor = polled.cursor
        execution_started_at = polled.execution_started_at

        local native_kind, native_message =
            interpreter.classify_native(native_report)
        if native_kind then fail(native_kind, native_message) end
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
            local recovered, recovery_error = recovery.after_failure(
                options, runner, run_id, owner_capability,
                expected_identity, event_cursor)
            if recovered then
                consume_transport(recovered, false,
                    not diagnostic_formatting_failed)
            end
            runner_error = recovery.preserve_error(runner_error, recovery_error)
        end
    end

    local final_exit_code = runner_error and runner_error.exit_code or
        exit_codes[RunnerFailureKind.SUCCESS]
    local final_state = runner_error and interpreter.failure_state(
        runner_error, native_report, interrupted) or
        native_report.state
    local final_result = interpreter.build(options, native_report,
        final_state, true, final_exit_code, submitted_at, activated_at,
        timestamp(options), runner_error, event_journal)
    local write_ok, write_error = pcall(interpreter.persist, options, final_result)
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
        persisted_result = interpreter.build(options, native_report,
            interpreter.states.PERSISTENCE_ERROR, true, runner_error.exit_code,
            submitted_at, activated_at, timestamp(options), runner_error,
            event_journal)
    end

    if write_ok and native_report and native_report.terminal and
            owner_capability ~= nil then
        local acknowledge_ok, acknowledge_error = pcall(
            recovery.acknowledge, options, runner, run_id,
            native_report.generation, owner_capability, expected_identity,
            event_cursor)
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
    local runner, resolve_error = client.resolve(options)
    if not runner then
        return {exit_code=resolve_error.exit_code, error=resolve_error}
    end
    if options.verbose and options.emit then
        options.emit('DFHack runner: ' .. runner)
    end
    local connected, connection_error = pcall(client.verify_connection,
        options, runner)
    if not connected then
        local detail = type(connection_error) == 'table' and
            connection_error or
            failure(RunnerFailureKind.CONNECTION,
                clean_message(connection_error))
        return {exit_code=detail.exit_code, error=detail}
    end
    return recovery.abort(options, runner, run_id)
end

---Reads the process-wide scheduler without changing service state.
---@param options table
---@return table
function M.status(options)
    local exists, status_script = builder.has_script(options, 'scheduler_status')
    if not exists then
        return {exit_code=exit_codes[RunnerFailureKind.DEPENDENCY],
            error=failure(RunnerFailureKind.DEPENDENCY,
                'DwarfSpec dependency was not found: ' .. status_script)}
    end
    local runner, resolve_error = client.resolve(options)
    if not runner then return {exit_code=resolve_error.exit_code, error=resolve_error} end
    if options.verbose and options.emit then
        options.emit('DFHack runner: ' .. runner)
    end
    local connected, connection_error = pcall(client.verify_connection,
        options, runner)
    if not connected then
        local detail = type(connection_error) == 'table' and
            connection_error or
            failure(RunnerFailureKind.CONNECTION,
                clean_message(connection_error))
        return {exit_code=detail.exit_code, error=detail}
    end
    local parsed, status = pcall(client.scheduler_status, options, runner)
    if not parsed then
        return {exit_code=exit_codes[RunnerFailureKind.HOST],
            error=failure(RunnerFailureKind.HOST,
                clean_message(status))}
    end
    return {
        exit_code=exit_codes[RunnerFailureKind.SUCCESS],
        status=status,
        scheduler=status.scheduler,
    }
end

---Invokes one read-only retained-run query through dfhack-run.
---@param options table
---@param operation string
---@param run_id string|nil
---@return table
local function read_run_query(options, operation, run_id)
    local exists, query_script = builder.has_script(options, 'run_query')
    if not exists then
        return {exit_code=exit_codes[RunnerFailureKind.DEPENDENCY],
            error=failure(RunnerFailureKind.DEPENDENCY,
                'DwarfSpec dependency was not found: ' .. query_script)}
    end
    local resolved_runner, resolve_error = client.resolve(options)
    if not resolved_runner then
        return {exit_code=resolve_error.exit_code, error=resolve_error}
    end
    if options.verbose and options.emit then
        options.emit('DFHack runner: ' .. resolved_runner)
    end
    local connected, connection_error = pcall(client.verify_connection,
        options, resolved_runner)
    if not connected then
        local detail = type(connection_error) == 'table' and
            connection_error or
            failure(RunnerFailureKind.CONNECTION,
                clean_message(connection_error))
        return {exit_code=detail.exit_code, error=detail}
    end
    local parsed, response = pcall(client.query, options, resolved_runner,
        operation, run_id)
    if not parsed then
        return {exit_code=exit_codes[RunnerFailureKind.HOST],
            error=failure(RunnerFailureKind.HOST,
                clean_message(response))}
    end
    if response.found == false then
        local message = response.service_loaded and
            ('DwarfSpec run was not found: ' .. tostring(run_id)) or
            ('DwarfSpec service is not loaded; run was not found: ' ..
                tostring(run_id))
        return {exit_code=exit_codes[RunnerFailureKind.HOST],
            error=failure(RunnerFailureKind.HOST, message),
            response=response}
    end
    return {
        exit_code=exit_codes[RunnerFailureKind.SUCCESS],
        response=response,
    }
end

---Lists all runs retained by the current DFHack service instance.
---@param options table
---@return table
function M.history(options)
    local outcome = read_run_query(options, 'history', nil)
    outcome.history = outcome.response
    return outcome
end

---Inspects one retained run without renewing its lease.
---@param options table
---@param run_id string
---@return table
function M.inspect(options, run_id)
    local outcome = read_run_query(options, 'show', run_id)
    outcome.inspection = outcome.response
    return outcome
end

---Reads captured output for one retained run without changing service state.
---@param options table
---@param run_id string
---@return table
function M.logs(options, run_id)
    local outcome = read_run_query(options, 'logs', run_id)
    outcome.logs = outcome.response
    return outcome
end

---Recovers one exact quarantined executor after host clean-state verification.
---@param options table
---@param run_id string
---@param generation integer
---@param reason string
---@return table
function M.recover_executor(options, run_id, generation, reason)
    local exists, recovery_script = builder.has_script(options, 'recover_executor')
    if not exists then
        return {exit_code=exit_codes[RunnerFailureKind.DEPENDENCY],
            error=failure(RunnerFailureKind.DEPENDENCY,
                'DwarfSpec dependency was not found: ' .. recovery_script)}
    end
    local runner, resolve_error = client.resolve(options)
    if not runner then return {exit_code=resolve_error.exit_code, error=resolve_error} end
    if options.verbose and options.emit then
        options.emit('DFHack runner: ' .. runner)
    end
    local connected, connection_error = pcall(client.verify_connection,
        options, runner)
    if not connected then
        local detail = type(connection_error) == 'table' and
            connection_error or
            failure(RunnerFailureKind.CONNECTION,
                clean_message(connection_error))
        return {exit_code=detail.exit_code, error=detail}
    end
    return recovery.recover_executor(options, runner, run_id, generation, reason)
end

return M
