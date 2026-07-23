-- Unit contracts for external orchestration, recovery, and exit propagation.

local json = require('dkjson')
local runner = require('dwarfspec.runner')
local EventType = require('dwarfspec.automation.event_types')
local ResultState = require('dwarfspec.automation.result_states')
local RunState = require('dwarfspec.automation.run_states')

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

local OWNER_CAPABILITY = 'runner-owner-capability-000000000001'

---Returns the cursor argument used by one transport adapter invocation.
---@param arguments string[]
---@return integer
local function transport_cursor(arguments)
    local script = arguments[3]
    if script:match('acknowledge%.lua$') then
        return tonumber(arguments[7]) or 0
    end
    return tonumber(arguments[6]) or 0
end

---Builds one canonical version 2 transport output line.
---@param run_id string
---@param state DwarfSpecRunState
---@param cleanup_confirmed boolean
---@param output_count integer|nil
---@param after_sequence integer|nil
---@return string[]
local function report_lines(run_id, state, cleanup_confirmed, output_count,
        after_sequence)
    assert(RUN_STATE_TERMINAL[state] ~= nil,
        'fixture state must be a RunState')
    after_sequence = after_sequence or 0
    local transport_events = {}
    if output_count then
        table.insert(transport_events, {
            schema='dwarfspec.event.v1',
            service_instance_id='service-runner-fixture',
            project_id='project-runner-fixture',
            run_id=run_id,
            generation=1,
            sequence=after_sequence + 1,
            type=EventType.TEST_STARTED,
            elapsed_ms=1,
            payload={name='progress line'},
        })
    end
    local last_sequence = after_sequence + #transport_events
    local snapshot = {
        schema='dwarfspec.run.v2',
        protocol_version=2,
        service_instance_id='service-runner-fixture',
        project_id='project-runner-fixture',
        run_id=run_id,
        state=state,
        terminal=RUN_STATE_TERMINAL[state],
        generation=1,
        submitted_at_ms=100,
        last_sequence=last_sequence,
        owner_kind='external',
        counts={successes=state == RunState.PASSED and 1 or 0,
            failures=state == RunState.FAILED and 1 or 0,
            errors=0, pending=0},
        totals={successes=state == RunState.PASSED and 1 or 0,
            failures=state == RunState.FAILED and 1 or 0,
            errors=0, pending=0},
        queue_lease={active=state == RunState.QUEUED},
        execution_lease={active=not RUN_STATE_TERMINAL[state] and
            state ~= RunState.QUEUED},
        cleanup_confirmed=cleanup_confirmed,
        mount_cleanup_verified=cleanup_confirmed,
        failures={},
    }
    if state ~= RunState.QUEUED and state ~= RunState.CANCELLED then
        snapshot.activated_at_ms = 101
        snapshot.queue_wait_ms = 1
    end
    local transport = {
        schema='dwarfspec.transport.v2',
        protocol=2,
        service_instance_id=snapshot.service_instance_id,
        project_id=snapshot.project_id,
        run_id=run_id,
        generation=1,
        snapshot=snapshot,
        events=transport_events,
        last_sequence=last_sequence,
    }
    return {'DWARFSPEC_JSON ' .. json.encode(transport)}
end

---Builds transport output, including the bootstrap-only owner capability.
---@param arguments string[]
---@param run_id string
---@param state DwarfSpecRunState
---@param cleanup_confirmed boolean
---@param output_count integer|nil
---@return string[]
local function transport_lines(arguments, run_id, state, cleanup_confirmed,
        output_count)
    local after_sequence = transport_cursor(arguments)
    local lines = report_lines(run_id, state, cleanup_confirmed, output_count,
        after_sequence)
    if arguments[3]:match('bootstrap%.lua$') then
        table.insert(lines, 1, 'DWARFSPEC_OWNER ' .. OWNER_CAPABILITY)
    end
    return lines
end

---Builds one queued bootstrap transport response.
---@param run_id string
---@return string[]
local function bootstrap_sequence(run_id)
    local lines = report_lines(run_id, RunState.QUEUED, false)
    table.insert(lines, 1, 'DWARFSPEC_OWNER ' .. OWNER_CAPABILITY)
    return lines
end

---Returns the smallest complete source-run option table.
---@param run_id string
---@return table
local function options(run_id)
    return {
        package_root='.',
        project_root='tests/framework/minimal_project',
        test_glob='tests/automation/*.lua',
        identities={'tests/automation/minimal_spec.lua'},
        runner='bin/dwarfspec',
        filters={}, filter_out={}, names={}, tags={}, exclude_tags={},
        repeat_count=1,
        timeout_seconds=30,
        queue_timeout_seconds=nil,
        poll_interval_ms=1,
        startup_delay_frames=1,
        lease_timeout_ms=5000,
        lease_check_frames=30,
        result_path=false,
        run_id=run_id,
        verbose=false,
        system={monotime=function() return 0 end, sleep=function() end},
    }
end

describe('DwarfSpec external runner', function()
    it('streams progress and returns zero only after passing cleanup', function()
        local calls = 0
        local emitted = {}
        local bootstrap_arguments
        local run_options = options('pass-run')
        run_options.emit = function(line) table.insert(emitted, line) end
        run_options.invoke = function(_, arguments)
            calls = calls + 1
            if arguments[3]:match('probe%.lua$') then
                return {exit_code=0, lines={
                    'DWARFSPEC_PROBE protocol=1 core=true timeout=function'}}
            elseif arguments[3]:match('bootstrap%.lua$') then
                bootstrap_arguments = arguments
                return {exit_code=0,
                    lines=transport_lines(arguments,
                        'pass-run', RunState.STARTING, false)}
            end
            return {exit_code=0,
                    lines=transport_lines(arguments,
                        'pass-run', RunState.PASSED, true, 1)}
        end

        local outcome = runner.run(run_options)

        assert.equals(0, outcome.exit_code)
        assert.equals(RunState.PASSED, outcome.report.state)
        assert.equals(ResultState.PASSED, outcome.result.state)
        assert.equals('dwarfspec.result.v2', outcome.result.schema)
        assert.same({'START progress line'}, emitted)
        assert.equals(EventType.TEST_STARTED, outcome.result.events[1].type)
        assert.equals(4, calls)
        local test_glob_found = false
        local lua_module_root_found = false
        local no_results_policy_found = false
        local result_path_found = false
        for _, argument in ipairs(bootstrap_arguments) do
            if argument == '--test-glob=tests/automation/*.lua' then
                test_glob_found = true
            end
            if argument:match('^%-%-lua%-module%-root=') then
                lua_module_root_found = true
            end
            if argument == '--result-policy=none' then
                no_results_policy_found = true
            end
            if argument:match('^%-%-result%-path=') then
                result_path_found = true
            end
        end
        assert.is_true(test_glob_found)
        assert.is_true(lua_module_root_found)
        assert.is_true(no_results_policy_found)
        assert.is_false(result_path_found)
    end)

    it('persists queued, activation, and complete terminal documents in order',
            function()
        local states = {}
        local result_paths = {}
        local bootstrap_arguments_seen
        local status_calls = 0
        local run_options = options('state-transitions')
        run_options.result_path = 'D:/results with spaces/results.json'
        run_options.result_store = {
            write=function(path, result)
                table.insert(result_paths, path)
                table.insert(states, result.state)
            end,
        }
        run_options.invoke = function(_, arguments)
            if arguments[3]:match('probe%.lua$') then
                return {exit_code=0, lines={
                    'DWARFSPEC_PROBE protocol=1 core=true timeout=function'}}
            elseif arguments[3]:match('bootstrap%.lua$') then
                bootstrap_arguments_seen = arguments
                return {exit_code=0,
                    lines=bootstrap_sequence('state-transitions')}
            elseif arguments[3]:match('status%.lua$') then
                status_calls = status_calls + 1
                local state = status_calls == 1 and RunState.STARTING or
                    RunState.PASSED
                return {exit_code=0,
                    lines=transport_lines(arguments,
                        'state-transitions', state,
                        state == RunState.PASSED)}
            end
            return {exit_code=0,
                lines=report_lines(
                    'state-transitions', RunState.PASSED, true)}
        end

        local outcome = runner.run(run_options)

        assert.equals(0, outcome.exit_code)
        assert.same({
            ResultState.QUEUED,
            ResultState.STARTING,
            ResultState.PASSED,
            ResultState.PASSED,
        }, states)
        for _, path in ipairs(result_paths) do
            assert.equals(run_options.result_path, path)
        end
        local bootstrap_text = table.concat(bootstrap_arguments_seen, '\n')
        assert.is_not_nil(bootstrap_text:match('%-%-result%-policy=file'))
        assert.is_not_nil(bootstrap_text:match(
            '%-%-result%-path=D:/results with spaces/results.json'))
    end)

    it('propagates Busted failures without issuing a recovery abort', function()
        local calls = {}
        local run_options = options('failed-run')
        run_options.invoke = function(_, arguments)
            table.insert(calls, arguments[3])
            if arguments[3]:match('probe%.lua$') then
                return {exit_code=0, lines={
                    'DWARFSPEC_PROBE protocol=1 core=true timeout=function'}}
            end
            return {exit_code=0,
                    lines=transport_lines(arguments,
                        'failed-run', RunState.FAILED, true)}
        end
        local outcome = runner.run(run_options)
        assert.equals(runner.exit_codes[runner.failure_kinds.TEST],
            outcome.exit_code)
        assert.equals(ResultState.FAILED, outcome.result.state)
        assert.matches('finished with state failed', outcome.error.message,
            1, true)
        assert.equals(3, #calls)
    end)

    it('times out, aborts, and preserves confirmed cleanup', function()
        local clock = 0
        local calls = {}
        local run_options = options('timeout-run')
        run_options.timeout_seconds = 1
        run_options.now = function()
            clock = clock + 1
            return clock
        end
        run_options.invoke = function(_, arguments)
            table.insert(calls, arguments[3])
            if arguments[3]:match('probe%.lua$') then
                return {exit_code=0, lines={
                    'DWARFSPEC_PROBE protocol=1 core=true timeout=function'}}
            elseif arguments[3]:match('bootstrap%.lua$') then
                return {exit_code=0,
                    lines=transport_lines(arguments,
                        'timeout-run', RunState.STARTING, false)}
            end
            return {exit_code=0,
                    lines=transport_lines(arguments,
                        'timeout-run', RunState.ABORTED, true)}
        end
        local outcome = runner.run(run_options)
        assert.equals(runner.exit_codes[runner.failure_kinds.TIMEOUT],
            outcome.exit_code)
        assert.equals(RunState.ABORTED,
            outcome.report.state)
        assert.equals(ResultState.TIMEOUT, outcome.result.state)
        assert.is_true(table.concat(calls, '\n'):match('recover%.lua') ~= nil)
    end)

    it('classifies a queued external timeout separately from active timeout',
            function()
        local clock = 0
        local run_options = options('queue-timeout')
        run_options.queue_timeout_seconds = 1
        run_options.now = function()
            clock = clock + 1
            return clock
        end
        run_options.invoke = function(_, arguments)
            if arguments[3]:match('probe%.lua$') then
                return {exit_code=0, lines={
                    'DWARFSPEC_PROBE protocol=1 core=true timeout=function'}}
            elseif arguments[3]:match('bootstrap%.lua$') then
                return {exit_code=0,
                    lines=transport_lines(arguments,
                        'queue-timeout', RunState.QUEUED, false)}
            end
            return {exit_code=0,
                lines=transport_lines(arguments,
                    'queue-timeout', RunState.CANCELLED, true)}
        end

        local outcome = runner.run(run_options)

        assert.equals(runner.exit_codes[runner.failure_kinds.TIMEOUT],
            outcome.exit_code)
        assert.equals(ResultState.QUEUE_TIMEOUT, outcome.result.state)
    end)

    it('does not consume execution timeout while waiting in the queue',
            function()
        local clock = 0
        local status_calls = 0
        local run_options = options('separate-timeout-budgets')
        run_options.timeout_seconds = 1
        run_options.now = function() return clock end
        run_options.sleep = function()
            if status_calls == 0 then
                clock = clock + 100
            else
                clock = clock + 0.1
            end
        end
        run_options.invoke = function(_, arguments)
            if arguments[3]:match('probe%.lua$') then
                return {exit_code=0, lines={
                    'DWARFSPEC_PROBE protocol=1 core=true timeout=function'}}
            elseif arguments[3]:match('bootstrap%.lua$') then
                return {exit_code=0, lines=transport_lines(arguments,
                    'separate-timeout-budgets', RunState.QUEUED, false)}
            elseif arguments[3]:match('status%.lua$') then
                status_calls = status_calls + 1
                local state = status_calls == 1 and RunState.STARTING or
                    RunState.PASSED
                return {exit_code=0, lines=transport_lines(arguments,
                    'separate-timeout-budgets', state,
                    state == RunState.PASSED)}
            end
            return {exit_code=0, lines=transport_lines(arguments,
                'separate-timeout-budgets', RunState.PASSED, true)}
        end

        local outcome = runner.run(run_options)

        assert.equals(runner.exit_codes[runner.failure_kinds.SUCCESS],
            outcome.exit_code)
        assert.equals(ResultState.PASSED, outcome.result.state)
        assert.equals(2, status_calls)
    end)

    it('retries an ambiguous submit with the identical idempotency input',
            function()
        local bootstrap_calls = {}
        local run_options = options('ambiguous-submit')
        run_options.invoke = function(_, arguments)
            if arguments[3]:match('probe%.lua$') then
                return {exit_code=0, lines={
                    'DWARFSPEC_PROBE protocol=1 core=true timeout=function'}}
            elseif arguments[3]:match('bootstrap%.lua$') then
                table.insert(bootstrap_calls, table.concat(arguments, '\0'))
                if #bootstrap_calls == 1 then
                    error('bridge response was lost after submission')
                end
                return {exit_code=0, lines=transport_lines(arguments,
                    'ambiguous-submit', RunState.QUEUED, false)}
            elseif arguments[3]:match('status%.lua$') then
                return {exit_code=0, lines=transport_lines(arguments,
                    'ambiguous-submit', RunState.PASSED, true)}
            end
            return {exit_code=0, lines=transport_lines(arguments,
                'ambiguous-submit', RunState.PASSED, true)}
        end

        local outcome = runner.run(run_options)

        assert.equals(runner.exit_codes[runner.failure_kinds.SUCCESS],
            outcome.exit_code)
        assert.equals(2, #bootstrap_calls)
        assert.equals(bootstrap_calls[1], bootstrap_calls[2])
    end)

    it('persists cancellation before native execution without a host report',
            function()
        local run_options = options('cancelled-run')
        run_options.invoke = function(_, arguments)
            if arguments[3]:match('probe%.lua$') then
                return {exit_code=0, lines={
                    'DWARFSPEC_PROBE protocol=1 core=true timeout=function'}}
            end
            return {exit_code=0,
                lines=transport_lines(arguments,
                    'cancelled-run', RunState.CANCELLED, true)}
        end

        local outcome = runner.run(run_options)

        assert.equals(runner.exit_codes[runner.failure_kinds.CANCELLED],
            outcome.exit_code)
        assert.equals(ResultState.CANCELLED, outcome.result.state)
        assert.is_nil(outcome.result.host_report)
    end)

    it('recovers after a malformed status report', function()
        local status_seen = false
        local run_options = options('malformed-run')
        run_options.invoke = function(_, arguments)
            if arguments[3]:match('probe%.lua$') then
                return {exit_code=0, lines={
                    'DWARFSPEC_PROBE protocol=1 core=true timeout=function'}}
            elseif arguments[3]:match('bootstrap%.lua$') then
                return {exit_code=0,
                    lines=transport_lines(arguments,
                        'malformed-run', RunState.STARTING, false)}
            elseif arguments[3]:match('status%.lua$') then
                status_seen = true
                return {exit_code=0, lines={'not json'}}
            end
            return {exit_code=0,
                    lines=transport_lines(arguments,
                        'malformed-run', RunState.ABORTED, true)}
        end
        local outcome = runner.run(run_options)
        assert.is_true(status_seen)
        assert.equals(runner.exit_codes[runner.failure_kinds.HOST],
            outcome.exit_code)
        assert.equals(RunState.ABORTED,
            outcome.report.state)
        assert.equals(ResultState.HOST_ERROR, outcome.result.state)
        assert.matches('did not contain a DWARFSPEC_JSON report',
            outcome.error.message, 1, true)
    end)

    it('preserves malformed transport as primary when recovery also fails',
            function()
        local run_options = options('double-failure')
        run_options.invoke = function(_, arguments)
            if arguments[3]:match('probe%.lua$') then
                return {exit_code=0, lines={
                    'DWARFSPEC_PROBE protocol=1 core=true timeout=function'}}
            elseif arguments[3]:match('bootstrap%.lua$') then
                return {exit_code=0, lines=transport_lines(arguments,
                    'double-failure', RunState.STARTING, false)}
            elseif arguments[3]:match('status%.lua$') then
                return {exit_code=0, lines={'malformed status'}}
            end
            return {exit_code=13, lines={'recovery unavailable'}}
        end

        local outcome = runner.run(run_options)

        assert.equals(runner.exit_codes[runner.failure_kinds.HOST],
            outcome.exit_code)
        assert.matches('did not contain a DWARFSPEC_JSON report',
            outcome.error.message, 1, true)
        assert.matches('recovery failed: recovery exited with 13',
            outcome.error.message, 1, true)
    end)

    it('returns a connection failure before bootstrap', function()
        local run_options = options('connection-run')
        run_options.invoke = function()
            return {exit_code=1, lines={'not running'}}
        end
        local outcome = runner.run(run_options)
        assert.equals(runner.exit_codes[runner.failure_kinds.CONNECTION],
            outcome.exit_code)
        assert.equals(ResultState.CONNECTION_ERROR, outcome.result.state)
        assert.matches('DFHack is not running', outcome.error.message,
            1, true)
        assert.is_nil(outcome.report)
    end)

    it('classifies a missing configured runner as a dependency failure',
            function()
        local run_options = options('missing-runner')
        run_options.runner = 'tests/framework/runner_path/missing'
        local persisted
        run_options.result_path = 'D:/results/dependency.json'
        run_options.result_store = {
            write=function(_, result)
                persisted = result
            end,
        }
        local outcome = runner.run(run_options)
        assert.equals(runner.exit_codes[runner.failure_kinds.DEPENDENCY],
            outcome.exit_code)
        assert.equals(ResultState.DEPENDENCY_ERROR, outcome.result.state)
        assert.equals(ResultState.DEPENDENCY_ERROR, persisted.state)
        assert.is_nil(persisted.run_id)
        assert.matches('configured DFHack runner was not found',
            outcome.error.message, 1, true)
    end)

    it('classifies a probe launch exception as an actionable connection error',
            function()
        local run_options = options('probe-launch')
        run_options.invoke = function()
            error('process launch failed')
        end
        local outcome = runner.run(run_options)
        assert.equals(runner.exit_codes[runner.failure_kinds.CONNECTION],
            outcome.exit_code)
        assert.equals(ResultState.CONNECTION_ERROR, outcome.result.state)
        assert.matches('could not contact DFHack through',
            outcome.error.message, 1, true)
    end)

    it('treats interruption as abort and confirms native cleanup', function()
        local run_options = options('interrupted-run')
        run_options.sleep = function() error('interrupted by user') end
        run_options.invoke = function(_, arguments)
            if arguments[3]:match('probe%.lua$') then
                return {exit_code=0, lines={
                    'DWARFSPEC_PROBE protocol=1 core=true timeout=function'}}
            elseif arguments[3]:match('bootstrap%.lua$') then
                return {exit_code=0,
                    lines=transport_lines(arguments,
                        'interrupted-run', RunState.STARTING, false)}
            end
            return {exit_code=0,
                    lines=transport_lines(arguments,
                        'interrupted-run', RunState.ABORTED, true)}
        end
        local outcome = runner.run(run_options)
        assert.equals(runner.exit_codes[runner.failure_kinds.ABORTED],
            outcome.exit_code)
        assert.equals('DwarfSpec run interrupted', outcome.error.message)
        assert.equals(RunState.ABORTED,
            outcome.report.state)
        assert.equals(ResultState.INTERRUPTED, outcome.result.state)
        assert.is_true(outcome.report.cleanup_confirmed)
    end)

    it('rejects a passing native result without cleanup confirmation', function()
        local run_options = options('unclean-run')
        run_options.invoke = function(_, arguments)
            if arguments[3]:match('probe%.lua$') then
                return {exit_code=0, lines={
                    'DWARFSPEC_PROBE protocol=1 core=true timeout=function'}}
            end
            return {exit_code=0,
                lines=transport_lines(arguments,
                    'unclean-run', RunState.PASSED, false)}
        end
        local outcome = runner.run(run_options)
        assert.equals(runner.exit_codes[runner.failure_kinds.TEST],
            outcome.exit_code)
        assert.equals(ResultState.FAILED, outcome.result.state)
        assert.matches('without confirmed cleanup', outcome.error.message,
            1, true)
    end)

    it('prints the resolved runner while explicitly aborting in verbose mode',
            function()
        local emitted = {}
        local run_options = options('explicit-abort')
        run_options.verbose = true
        run_options.emit = function(line) table.insert(emitted, line) end
        run_options.invoke = function(_, arguments)
            if arguments[3]:match('probe%.lua$') then
                return {exit_code=0, lines={
                    'DWARFSPEC_PROBE protocol=1 core=true timeout=function'}}
            end
            return {exit_code=0,
                lines=transport_lines(arguments,
                    'explicit-abort', RunState.ABORTED, true)}
        end
        local outcome = runner.abort(run_options, 'explicit-abort')
        assert.equals(0, outcome.exit_code)
        assert.same({'DFHack runner: bin/dwarfspec'}, emitted)
    end)

    it('classifies bootstrap failure and preserves recovery cleanup', function()
        local run_options = options('bootstrap-failure')
        run_options.invoke = function(_, arguments)
            if arguments[3]:match('probe%.lua$') then
                return {exit_code=0, lines={
                    'DWARFSPEC_PROBE protocol=1 core=true timeout=function'}}
            elseif arguments[3]:match('bootstrap%.lua$') then
                return {exit_code=9, lines={'bootstrap failed'}}
            end
            return {exit_code=0,
                    lines=transport_lines(arguments,
                        'bootstrap-failure', RunState.ABORTED, true)}
        end
        local outcome = runner.run(run_options)
        assert.equals(runner.exit_codes[runner.failure_kinds.HOST],
            outcome.exit_code)
        assert.equals(ResultState.REGISTRATION_ERROR, outcome.result.state)
        assert.matches('bootstrap exited with 9', outcome.error.message,
            1, true)
        assert.equals(RunState.ABORTED,
            outcome.report.state)
    end)

    it('surfaces an explicit registration rejection without recovery',
            function()
        local bootstrap_calls = 0
        local recovery_calls = 0
        local run_options = options('version-rejection')
        run_options.invoke = function(_, arguments)
            if arguments[3]:match('probe%.lua$') then
                return {exit_code=0, lines={
                    'DWARFSPEC_PROBE protocol=1 core=true timeout=function'}}
            elseif arguments[3]:match('bootstrap%.lua$') then
                bootstrap_calls = bootstrap_calls + 1
                return {exit_code=0, lines={'DWARFSPEC_JSON ' .. json.encode({
                    schema='dwarfspec.error.v1',
                    protocol=2,
                    kind=runner.failure_kinds.REGISTRATION,
                    message='incompatible automation package version: ' ..
                        'expected 0.1.3, found 0.2.0',
                })}}
            end
            recovery_calls = recovery_calls + 1
            return {exit_code=0, lines={}}
        end

        local outcome = runner.run(run_options)

        assert.equals(1, bootstrap_calls)
        assert.equals(0, recovery_calls)
        assert.equals(runner.exit_codes[
            runner.failure_kinds.REGISTRATION], outcome.exit_code)
        assert.equals(runner.failure_kinds.REGISTRATION, outcome.error.kind)
        assert.equals(ResultState.REGISTRATION_ERROR, outcome.result.state)
        assert.matches('expected 0.1.3, found 0.2.0',
            outcome.error.message, 1, true)
        assert.matches('Restart DFHack', outcome.error.message, 1, true)
        assert.is_nil(outcome.report)
    end)

    it('classifies status transport failure and recovers cleanup', function()
        local run_options = options('status-failure')
        run_options.invoke = function(_, arguments)
            if arguments[3]:match('probe%.lua$') then
                return {exit_code=0, lines={
                    'DWARFSPEC_PROBE protocol=1 core=true timeout=function'}}
            elseif arguments[3]:match('bootstrap%.lua$') then
                return {exit_code=0,
                    lines=transport_lines(arguments,
                        'status-failure', RunState.STARTING, false)}
            elseif arguments[3]:match('status%.lua$') then
                return {exit_code=11, lines={'status failed'}}
            end
            return {exit_code=0,
                    lines=transport_lines(arguments,
                        'status-failure', RunState.ABORTED, true)}
        end
        local outcome = runner.run(run_options)
        assert.equals(runner.exit_codes[runner.failure_kinds.HOST],
            outcome.exit_code)
        assert.matches('status exited with 11', outcome.error.message,
            1, true)
        assert.equals(RunState.ABORTED,
            outcome.report.state)
        assert.equals(ResultState.HOST_ERROR, outcome.result.state)
    end)

    it('propagates a host-reported abort with its stable exit code', function()
        local run_options = options('host-aborted')
        run_options.invoke = function(_, arguments)
            if arguments[3]:match('probe%.lua$') then
                return {exit_code=0, lines={
                    'DWARFSPEC_PROBE protocol=1 core=true timeout=function'}}
            end
            return {exit_code=0,
                    lines=transport_lines(arguments,
                        'host-aborted', RunState.ABORTED, true)}
        end
        local outcome = runner.run(run_options)
        assert.equals(runner.exit_codes[runner.failure_kinds.ABORTED],
            outcome.exit_code)
        assert.equals(ResultState.ABORTED, outcome.result.state)
        assert.equals(RunState.ABORTED,
            outcome.report.state)
    end)

    it('reports result persistence failures after a passing native run',
            function()
        local run_options = options('write-failure')
        local calls = {}
        run_options.result_path = require('lfs').currentdir() ..
            '/tests/unit/runner_spec.lua/results.json'
        run_options.invoke = function(_, arguments)
            table.insert(calls, arguments[3])
            if arguments[3]:match('probe%.lua$') then
                return {exit_code=0, lines={
                    'DWARFSPEC_PROBE protocol=1 core=true timeout=function'}}
            end
            return {exit_code=0,
                    lines=transport_lines(arguments,
                        'write-failure', RunState.PASSED, true)}
        end
        local outcome = runner.run(run_options)
        assert.equals(runner.exit_codes[runner.failure_kinds.HOST],
            outcome.exit_code)
        assert.equals(ResultState.PERSISTENCE_ERROR, outcome.result.state)
        assert.matches('could not create directory', outcome.error.message,
            1, true)
        assert.is_nil(table.concat(calls, '\n'):match('acknowledge%.lua'))
    end)

    it('writes one stable version 2 latest-result file',
            function()
        local lfs = require('lfs')
        local result_directory = lfs.currentdir() ..
            '/tests/framework/command_project/' ..
            '.test-results/stable-result-contract'
        local result_path = result_directory .. '/results.json'
        os.remove(result_path)
        lfs.rmdir(result_directory)

        local run_options = options('stable-result')
        run_options.result_path = result_path
        run_options.invoke = function(_, arguments)
            if arguments[3]:match('probe%.lua$') then
                return {exit_code=0, lines={
                    'DWARFSPEC_PROBE protocol=1 core=true timeout=function'}}
            end
            return {exit_code=0,
                lines=transport_lines(arguments,
                    'stable-result', RunState.PASSED, true)}
        end

        local outcome = runner.run(run_options)
        local file = assert(io.open(result_path, 'rb'))
        local contents = assert(file:read('*a'))
        file:close()
        assert(os.remove(result_path))
        assert(lfs.rmdir(result_directory))
        local persisted = assert(json.decode(contents))

        assert.equals(runner.exit_codes[runner.failure_kinds.SUCCESS],
            outcome.exit_code)
        assert.equals('dwarfspec.result.v2', persisted.schema)
        assert.equals('stable-result', persisted.run_id)
        assert.equals(RunState.PASSED, persisted.state)
    end)
end)
