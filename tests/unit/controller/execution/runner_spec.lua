-- Unit contracts for external orchestration, recovery, and exit propagation.

local json = require('dkjson')
local runner = require('dwarfspec.controller.execution.runner')
local layout = require('dwarfspec.layout')
local EComparison =
    require('dwarfspec.protocol.diagnostics.base_screen_focus_comparisons')
local EventType = require('dwarfspec.protocol.enums.event_types')
local ErrorFormat = require('dwarfspec.protocol.configuration.error_formats')
local ResultState = require('dwarfspec.protocol.enums.result_states')
local RunState = require('dwarfspec.protocol.enums.run_states')
local SchedulerFailureKind =
    require('dwarfspec.protocol.enums.scheduler_failure_kinds')

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

---Builds one version 2 scheduler snapshot.
---@param quarantine table|nil
---@return table
local function scheduler_snapshot(quarantine)
    return {
        schema='dwarfspec.scheduler.v2',
        protocol_version=2,
        service_instance_id='service-runner-fixture',
        package_root='D:/Packages/DwarfSpec',
        package_version='0.2.1',
        queue={},
        projects={},
        quarantine=quarantine or {active=false},
    }
end

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

---Builds transport output with caller-supplied event payloads.
---@param arguments string[]
---@param run_id string
---@param state DwarfSpecRunState
---@param cleanup_confirmed boolean
---@param event_values table[]
---@return string[]
local function transport_with_events(arguments, run_id, state,
        cleanup_confirmed, event_values)
    local after_sequence = transport_cursor(arguments)
    local lines = report_lines(run_id, state, cleanup_confirmed, nil,
        after_sequence)
    local encoded = assert(lines[1]:match('^DWARFSPEC_JSON (.+)$'))
    local transport = assert(json.decode(encoded))
    transport.events = {}
    for index, value in ipairs(event_values) do
        table.insert(transport.events, {
            schema='dwarfspec.event.v1',
            service_instance_id=transport.service_instance_id,
            project_id=transport.project_id,
            run_id=run_id,
            generation=transport.generation,
            sequence=after_sequence + index,
            type=value.type,
            elapsed_ms=index,
            payload=value.payload,
        })
    end
    transport.last_sequence = after_sequence + #transport.events
    transport.snapshot.last_sequence = transport.last_sequence
    lines = {'DWARFSPEC_JSON ' .. json.encode(transport)}
    if arguments[3]:match('bootstrap%.lua$') then
        table.insert(lines, 1, 'DWARFSPEC_OWNER ' .. OWNER_CAPABILITY)
    end
    return lines
end

---Returns ordered progress events surrounding one assertion failure.
---@param message string|nil
---@return table[]
local function diagnostic_events(message)
    return {
        {
            type=EventType.TEST_STARTED,
            payload={name='suite example'},
        },
        {
            type=EventType.PROBLEM_RECORDED,
            payload={
                kind='failure',
                name='suite example',
                message=message or 'expected true',
                trace='original trace',
                source_identity='tests/example.ds.lua',
                line=12,
                column=4,
            },
        },
        {
            type=EventType.TEST_FINISHED,
            payload={
                name='suite example',
                status='failure',
                duration_ms=5,
            },
        },
    }
end

---Returns one valid example focus-warning event value.
---@return table
local function focus_warning_event()
    local details = {
        screen={status='present', type='viewscreen_dwarfmodest'},
        focus={status='available', values={'dwarfmode/Default'}},
    }
    return {
        type=EventType.DIAGNOSTIC_RECORDED,
        payload={
            kind='base_screen_focus_changed',
            content={
                severity='warning',
                scope='example',
                attribution='test',
                suite_name='tests/focus_spec.lua',
                example_name='focus suite changes focus',
                source_identity='tests/focus_spec.lua',
                repeat_index=1,
                screen_comparison=EComparison.CHANGED,
                focus_comparison=EComparison.SAME,
                details_complete=true,
                before=details,
                after=details,
            },
        },
    }
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
        host_scripts=layout.current().host_scripts,
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

---Runs one representative failed probe through the complete run boundary.
---@param case table
---@return table, table
local function run_probe_failure(case)
    local run_options = options('connection-' .. case.name)
    run_options.identities = {'tests/private-selected-' .. case.name .. '.ds.lua'}
    run_options.test_glob = 'tests/private-selection-' .. case.name .. '/*.lua'
    run_options.result_path = 'D:/results/connection-' .. case.name .. '.json'
    local persisted
    run_options.result_store = {
        write=function(_, result) persisted = result end,
    }
    local calls = 0
    local bootstrap_attempted = false
    run_options.invoke = function(_, arguments)
        calls = calls + 1
        if not arguments[3]:match('probe%.lua$') then
            bootstrap_attempted = true
        end
        if case.exception then error(case.exception) end
        return case.result
    end

    local outcome = runner.run(run_options)

    assert.equals(4, outcome.exit_code, case.name)
    assert.same(runner.failure_kinds.CONNECTION, outcome.error.kind, case.name)
    assert.equals(ResultState.CONNECTION_ERROR, outcome.result.state, case.name)
    assert.equals(ResultState.CONNECTION_ERROR, persisted.state, case.name)
    assert.is_false(bootstrap_attempted, case.name)
    assert.equals(1, calls, case.name)
    assert.is_truthy(outcome.error.message:find(case.message, 1, true), case.name)
    for _, selected_path in ipairs({
            run_options.project_root, run_options.test_glob,
            run_options.identities[1],
        }) do
        assert.is_falsy(outcome.error.message:find(selected_path, 1, true),
            case.name .. ': ' .. selected_path)
    end
    return outcome, persisted
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
                    'DWARFSPEC_PROBE protocol=2 core=true timeout=function'}}
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

    it('streams and persists a warning without changing a passing result',
            function()
        local emitted = {}
        local persisted
        local run_options = options('warning-pass-run')
        run_options.emit = function(line) table.insert(emitted, line) end
        run_options.result_store = {
            write=function(_, value) persisted = value end,
        }
        run_options.result_path = 'tests/.test-results/warning.json'
        run_options.invoke = function(_, arguments)
            if arguments[3]:match('probe%.lua$') then
                return {exit_code=0, lines={
                    'DWARFSPEC_PROBE protocol=2 core=true timeout=function'}}
            elseif arguments[3]:match('bootstrap%.lua$') then
                return {exit_code=0, lines=transport_lines(arguments,
                    'warning-pass-run', RunState.STARTING, false)}
            elseif arguments[3]:match('status%.lua$') then
                return {exit_code=0, lines=transport_with_events(arguments,
                    'warning-pass-run', RunState.PASSED, true,
                    {focus_warning_event()})}
            end
            assert.matches('acknowledge%.lua$', arguments[3])
            return {exit_code=0, lines=transport_lines(arguments,
                'warning-pass-run', RunState.PASSED, true)}
        end

        local outcome = runner.run(run_options)

        assert.equals(0, outcome.exit_code)
        assert.equals(RunState.PASSED, outcome.report.state)
        assert.is_true(outcome.report.cleanup_confirmed)
        assert.equals(ResultState.PASSED, outcome.result.state)
        assert.equals(ResultState.PASSED, persisted.state)
        assert.equals(1, #persisted.events)
        assert.equals('base_screen_focus_changed',
            persisted.events[1].payload.kind)
        assert.same({
            'WARNING base-screen focus changed after example focus suite ' ..
                'changes focus in tests/focus_spec.lua (repeat=1 ' ..
                'attribution=test screen=changed focus=same complete=true)',
        }, emitted)
    end)

    it('streams each configured diagnostic format in event order and ' ..
            'persists the original failed event before acknowledgement',
            function()
        local cases = {
            {
                error_format=ErrorFormat.MSBUILD,
                expected='D:\\project\\tests\\example.ds.lua(12,4): ' ..
                    'error DS1001: suite example: expected true',
            },
            {
                error_format=ErrorFormat.GCC,
                expected='D:/project/tests/example.ds.lua:12:4: error: ' ..
                    'suite example: expected true',
            },
            {
                error_format=ErrorFormat.ESLINT,
                expected='tests/example.ds.lua: line 12, col 4, Error - ' ..
                    'suite example: expected true (dwarfspec)',
            },
        }
        for _, case in ipairs(cases) do
            local emitted = {}
            local persisted
            local acknowledged = false
            local run_options = options(
                'formatted-' .. case.error_format)
            run_options.project_root = 'D:\\project'
            run_options.error_format = case.error_format
            run_options.result_path = 'D:/results/result.json'
            run_options.result_store = {
                write=function(_, result) persisted = result end,
            }
            run_options.emit = function(line)
                table.insert(emitted, line)
            end
            run_options.invoke = function(_, arguments)
                if arguments[3]:match('probe%.lua$') then
                    return {exit_code=0, lines={
                        'DWARFSPEC_PROBE protocol=2 core=true ' ..
                            'timeout=function'}}
                elseif arguments[3]:match('bootstrap%.lua$') then
                    return {exit_code=0,
                        lines=transport_lines(arguments,
                            run_options.run_id, RunState.STARTING, false)}
                elseif arguments[3]:match('status%.lua$') then
                    return {exit_code=0,
                        lines=transport_with_events(arguments,
                            run_options.run_id, RunState.FAILED, true,
                            diagnostic_events())}
                end
                assert.matches('acknowledge%.lua$', arguments[3])
                acknowledged = true
                return {exit_code=0,
                    lines=transport_lines(arguments,
                        run_options.run_id, RunState.FAILED, true)}
            end

            local outcome = runner.run(run_options)

            assert.equals(runner.exit_codes[runner.failure_kinds.TEST],
                outcome.exit_code)
            assert.same({
                'START suite example',
                case.expected,
                'FAILURE suite example (5 ms)',
            }, emitted)
            assert.is_true(acknowledged)
            assert.equals(ResultState.FAILED, persisted.state)
            assert.equals(3, #persisted.events)
            local payload = persisted.events[2].payload
            assert.equals('expected true', payload.message)
            assert.equals('original trace', payload.trace)
            assert.equals('tests/example.ds.lua',
                payload.source_identity)
            assert.equals(12, payload.line)
            assert.equals(4, payload.column)
        end
    end)

    it('prints one diagnostic once across successive cursor polls', function()
        local emitted = {}
        local status_cursors = {}
        local status_calls = 0
        local run_options = options('cursor-diagnostic')
        run_options.project_root = 'D:\\project'
        run_options.error_format = ErrorFormat.GCC
        run_options.emit = function(line) table.insert(emitted, line) end
        run_options.invoke = function(_, arguments)
            if arguments[3]:match('probe%.lua$') then
                return {exit_code=0, lines={
                    'DWARFSPEC_PROBE protocol=2 core=true timeout=function'}}
            elseif arguments[3]:match('bootstrap%.lua$') then
                return {exit_code=0,
                    lines=transport_lines(arguments,
                        'cursor-diagnostic', RunState.STARTING, false)}
            elseif arguments[3]:match('status%.lua$') then
                status_calls = status_calls + 1
                table.insert(status_cursors, transport_cursor(arguments))
                if status_calls == 1 then
                    return {exit_code=0,
                        lines=transport_with_events(arguments,
                            'cursor-diagnostic', RunState.RUNNING, false,
                            diagnostic_events())}
                end
                return {exit_code=0,
                    lines=transport_with_events(arguments,
                        'cursor-diagnostic', RunState.PASSED, true, {})}
            end
            return {exit_code=0,
                lines=transport_lines(arguments,
                    'cursor-diagnostic', RunState.PASSED, true)}
        end

        local outcome = runner.run(run_options)

        assert.equals(0, outcome.exit_code)
        assert.same({0, 3}, status_cursors)
        local diagnostic_count = 0
        for _, line in ipairs(emitted) do
            if line:find(':12:4: error:', 1, true) then
                diagnostic_count = diagnostic_count + 1
            end
        end
        assert.equals(1, diagnostic_count)
        assert.equals(3, #outcome.result.events)
    end)

    it('classifies formatter failure and recovers active cleanup', function()
        local recovery_arguments
        local persisted
        local run_options = options('formatter-failure')
        run_options.project_root = 'D:\\project'
        run_options.error_format = ErrorFormat.MSBUILD
        run_options.result_path = 'D:/results/result.json'
        run_options.result_store = {
            write=function(_, result) persisted = result end,
        }
        run_options.diagnostic_formatter = {
            format=function()
                error('formatter exploded', 0)
            end,
        }
        run_options.invoke = function(_, arguments)
            if arguments[3]:match('probe%.lua$') then
                return {exit_code=0, lines={
                    'DWARFSPEC_PROBE protocol=2 core=true timeout=function'}}
            elseif arguments[3]:match('bootstrap%.lua$') then
                return {exit_code=0,
                    lines=transport_lines(arguments,
                        'formatter-failure', RunState.STARTING, false)}
            elseif arguments[3]:match('status%.lua$') then
                return {exit_code=0,
                    lines=transport_with_events(arguments,
                        'formatter-failure', RunState.RUNNING, false,
                        diagnostic_events())}
            end
            assert.matches('recover%.lua$', arguments[3])
            recovery_arguments = arguments
            return {exit_code=0,
                lines=transport_with_events(arguments,
                    'formatter-failure', RunState.ABORTED, true, {
                        {
                            type=EventType.CLEANUP_FINISHED,
                            payload={
                                cleanup_confirmed=true,
                                mount_cleanup_verified=true,
                            },
                        },
                    })}
        end

        local outcome = runner.run(run_options)

        assert.equals(runner.exit_codes[runner.failure_kinds.HOST],
            outcome.exit_code)
        assert.equals(runner.failure_kinds.HOST, outcome.error.kind)
        assert.matches('DwarfSpec diagnostic formatting failed: ' ..
            'formatter exploded', outcome.error.message, 1, true)
        assert.matches('recover%.lua$', recovery_arguments[3])
        assert.equals('3', recovery_arguments[6])
        assert.equals(RunState.ABORTED, outcome.report.state)
        assert.is_true(outcome.report.cleanup_confirmed)
        assert.equals(ResultState.HOST_ERROR, persisted.state)
        assert.equals(4, #persisted.events)
        assert.equals('expected true',
            persisted.events[2].payload.message)
        assert.equals(EventType.CLEANUP_FINISHED,
            persisted.events[4].type)
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
                    'DWARFSPEC_PROBE protocol=2 core=true timeout=function'}}
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
                    'DWARFSPEC_PROBE protocol=2 core=true timeout=function'}}
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
                    'DWARFSPEC_PROBE protocol=2 core=true timeout=function'}}
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
                    'DWARFSPEC_PROBE protocol=2 core=true timeout=function'}}
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
                    'DWARFSPEC_PROBE protocol=2 core=true timeout=function'}}
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
                    'DWARFSPEC_PROBE protocol=2 core=true timeout=function'}}
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
                    'DWARFSPEC_PROBE protocol=2 core=true timeout=function'}}
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
                    'DWARFSPEC_PROBE protocol=2 core=true timeout=function'}}
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
                    'DWARFSPEC_PROBE protocol=2 core=true timeout=function'}}
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

    it('preserves orchestration outcomes for every probe failure category', function()
        local cases = {
            {name='invocation', exception='process launch failed',
                message='Could not invoke DFHack runner "bin/dwarfspec":'},
            {name='nonzero', result={exit_code=1, lines={'not running'}},
                message='exited with code 1. Output: not running'},
            {name='missing', result={exit_code=0, lines={'ordinary output'}},
                message='emitted no DwarfSpec probe report'},
            {name='multiple', result={exit_code=0, lines={
                    'DWARFSPEC_PROBE protocol=2 core=true timeout=function',
                    'DWARFSPEC_PROBE protocol=2 core=true timeout=function',
                }}, message='emitted 2 DwarfSpec probe reports'},
            {name='malformed', result={exit_code=0, lines={
                    'DWARFSPEC_PROBE protocol=2 core=true',
                }}, message='malformed DwarfSpec probe report'},
            {name='protocol', result={exit_code=0, lines={
                    'DWARFSPEC_PROBE protocol=3 core=true timeout=function',
                }}, message='controller expects 2, probe reported 3'},
            {name='core', result={exit_code=0, lines={
                    'DWARFSPEC_PROBE protocol=2 core=false timeout=function',
                }}, message='reported core=false'},
            {name='timeout', result={exit_code=0, lines={
                    'DWARFSPEC_PROBE protocol=2 core=true timeout=nil',
                }}, message='reported timeout=nil'},
        }
        for _, case in ipairs(cases) do
            local outcome = run_probe_failure(case)
            assert.is_nil(outcome.report, case.name)
        end
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

    it('treats interruption as abort and confirms native cleanup', function()
        local run_options = options('interrupted-run')
        run_options.sleep = function() error('interrupted by user') end
        run_options.invoke = function(_, arguments)
            if arguments[3]:match('probe%.lua$') then
                return {exit_code=0, lines={
                    'DWARFSPEC_PROBE protocol=2 core=true timeout=function'}}
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
                    'DWARFSPEC_PROBE protocol=2 core=true timeout=function'}}
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
                    'DWARFSPEC_PROBE protocol=2 core=true timeout=function'}}
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
                    'DWARFSPEC_PROBE protocol=2 core=true timeout=function'}}
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
                    'DWARFSPEC_PROBE protocol=2 core=true timeout=function'}}
            elseif arguments[3]:match('bootstrap%.lua$') then
                bootstrap_calls = bootstrap_calls + 1
                return {exit_code=0, lines={'DWARFSPEC_JSON ' .. json.encode({
                    schema='dwarfspec.error.v1',
                    protocol=2,
                    kind=runner.failure_kinds.REGISTRATION,
                    code='package_version_mismatch',
                    message='different version loaded',
                    running_version='0.1.3',
                    requested_version='0.2.1',
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
        assert.equals(
            'DwarfSpec could not start because DFHack already has a ' ..
                'different DwarfSpec version loaded.\n\n' ..
                '  Running DFHack service: 0.1.3\n' ..
                '  Current DwarfSpec command: 0.2.1\n\n' ..
                'To use 0.2.1, save and fully exit Dwarf Fortress/DFHack, ' ..
                'relaunch it,\nand retry this command. Returning to the ' ..
                'title screen or unloading the\nworld will not unload the ' ..
                'process-wide DwarfSpec service.', outcome.error.message)
        assert.equals(outcome.error.message, outcome.result.error.message)
        assert.is_nil(outcome.error.message:find('expected', 1, true))
        assert.is_nil(outcome.error.message:find('found', 1, true))
        assert.is_nil(outcome.report)
    end)

    it('renders every admission conflict from its structured subtype without recovery',
            function()
        local cases = {
            {
                code=SchedulerFailureKind.PROJECT_BUSY,
                phrase='this project already has an outstanding run',
                action='Wait for that run to finish and consume its result',
            },
            {
                code=SchedulerFailureKind.REQUEST_KEY_CONFLICT,
                phrase='this request identity is already bound to a different run',
                action='submit this work with a new run identity',
            },
            {
                code=SchedulerFailureKind.RESULT_PATH_BUSY,
                phrase='configured result destination is reserved by another run',
                action='choose a different result destination',
            },
        }
        for _, case in ipairs(cases) do
            local bootstrap_calls = 0
            local recovery_calls = 0
            local run_options = options('admission-' .. case.code)
            run_options.invoke = function(_, arguments)
                if arguments[3]:match('probe%.lua$') then
                    return {exit_code=0, lines={
                        'DWARFSPEC_PROBE protocol=2 core=true timeout=function'}}
                elseif arguments[3]:match('bootstrap%.lua$') then
                    bootstrap_calls = bootstrap_calls + 1
                    return {exit_code=0, lines={'DWARFSPEC_JSON ' .. json.encode({
                        schema='dwarfspec.error.v1',
                        protocol=2,
                        kind=runner.failure_kinds.REGISTRATION,
                        code=case.code,
                        message='opaque host wording that must not be parsed',
                        blocking_run_id='blocking-run',
                        blocking_generation=9,
                        state='queued',
                        reason='scheduler classification detail',
                    })}}
                end
                recovery_calls = recovery_calls + 1
                return {exit_code=0, lines={}}
            end

            local outcome = runner.run(run_options)

            assert.equals(1, bootstrap_calls)
            assert.equals(0, recovery_calls)
            assert.equals(5, outcome.exit_code)
            assert.equals(runner.failure_kinds.REGISTRATION,
                outcome.error.kind)
            assert.equals(ResultState.REGISTRATION_ERROR,
                outcome.result.state)
            assert.equals(outcome.error.message,
                outcome.result.error.message)
            assert.matches(case.phrase, outcome.error.message, 1, true)
            assert.matches(case.action, outcome.error.message, 1, true)
            assert.matches('Blocking run: blocking-run',
                outcome.error.message, 1, true)
            assert.matches('Generation: 9', outcome.error.message, 1, true)
            assert.matches('State: queued', outcome.error.message, 1, true)
            assert.is_nil(outcome.error.message:find(
                'opaque host wording', 1, true))
            assert.is_nil(outcome.error.message:find(
                'selected specification', 1, true))
            assert.is_nil(outcome.report)
        end
    end)

    it('does not infer version guidance from generic registration text or code',
            function()
        local cases = {
            {
                name='generic-old-phrase',
                response={
                    schema='dwarfspec.error.v1',
                    protocol=2,
                    kind=runner.failure_kinds.REGISTRATION,
                    message='incompatible automation package version in ' ..
                        'unrelated registration detail',
                },
            },
            {
                name='unknown-code',
                response={
                    schema='dwarfspec.error.v1',
                    protocol=2,
                    kind=runner.failure_kinds.REGISTRATION,
                    code='future_registration_code',
                    message='future registration rejection',
                },
            },
        }
        for _, case in ipairs(cases) do
            local recovery_calls = 0
            local run_options = options(case.name)
            run_options.invoke = function(_, arguments)
                if arguments[3]:match('probe%.lua$') then
                    return {exit_code=0, lines={
                        'DWARFSPEC_PROBE protocol=2 core=true ' ..
                            'timeout=function'}}
                elseif arguments[3]:match('bootstrap%.lua$') then
                    return {exit_code=0, lines={
                        'DWARFSPEC_JSON ' .. json.encode(case.response)}}
                end
                recovery_calls = recovery_calls + 1
                return {exit_code=0, lines={}}
            end

            local outcome = runner.run(run_options)

            assert.equals(runner.exit_codes[
                runner.failure_kinds.REGISTRATION], outcome.exit_code)
            assert.equals(ResultState.REGISTRATION_ERROR,
                outcome.result.state)
            assert.matches(case.response.message, outcome.error.message,
                1, true)
            assert.is_nil(outcome.error.message:find(
                'Running DFHack service:', 1, true))
            assert.is_nil(outcome.error.message:find(
                'fully exit Dwarf Fortress/DFHack', 1, true))
            assert.equals(0, recovery_calls)
        end
    end)

    it('rejects a malformed mismatch response without recovery', function()
        local bootstrap_calls = 0
        local recovery_calls = 0
        local run_options = options('malformed-version-rejection')
        run_options.invoke = function(_, arguments)
            if arguments[3]:match('probe%.lua$') then
                return {exit_code=0, lines={
                    'DWARFSPEC_PROBE protocol=2 core=true timeout=function'}}
            elseif arguments[3]:match('bootstrap%.lua$') then
                bootstrap_calls = bootstrap_calls + 1
                return {exit_code=0, lines={'DWARFSPEC_JSON ' .. json.encode({
                    schema='dwarfspec.error.v1',
                    protocol=2,
                    kind=runner.failure_kinds.REGISTRATION,
                    code='package_version_mismatch',
                    message='different version loaded',
                    running_version='0.1.3',
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
        assert.matches('DwarfSpec bootstrap response was invalid',
            outcome.error.message, 1, true)
        assert.matches('requires requested version',
            outcome.error.message, 1, true)
        assert.is_nil(outcome.report)
    end)

    it('rejects quarantine before admission with a distinct result state',
            function()
        local bootstrap_calls = 0
        local run_options = options('quarantine-rejection')
        run_options.invoke = function(_, arguments)
            if arguments[3]:match('probe%.lua$') then
                return {exit_code=0, lines={
                    'DWARFSPEC_PROBE protocol=2 core=true timeout=function'}}
            end
            bootstrap_calls = bootstrap_calls + 1
            return {exit_code=0, lines={'DWARFSPEC_JSON ' .. json.encode({
                schema='dwarfspec.error.v1',
                protocol=2,
                kind=runner.failure_kinds.EXECUTOR_QUARANTINED,
                message='DwarfSpec executor is quarantined by run old-run ' ..
                    'generation 4: cleanup unconfirmed. Recover it with: ' ..
                    'dwarfspec recover-executor old-run --generation 4',
                blocking_run_id='old-run',
                blocking_generation=4,
                reason='cleanup unconfirmed',
            })}}
        end

        local outcome = runner.run(run_options)

        assert.equals(1, bootstrap_calls)
        assert.equals(runner.failure_kinds.EXECUTOR_QUARANTINED,
            outcome.error.kind)
        assert.equals(ResultState.EXECUTOR_QUARANTINED,
            outcome.result.state)
        assert.matches('recover-executor old-run --generation 4',
            outcome.error.message, 1, true)
        assert.is_nil(outcome.report)
    end)

    it('classifies status transport failure and recovers cleanup', function()
        local run_options = options('status-failure')
        run_options.invoke = function(_, arguments)
            if arguments[3]:match('probe%.lua$') then
                return {exit_code=0, lines={
                    'DWARFSPEC_PROBE protocol=2 core=true timeout=function'}}
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
                    'DWARFSPEC_PROBE protocol=2 core=true timeout=function'}}
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
            '/tests/unit/controller/execution/runner_spec.lua/results.json'
        run_options.invoke = function(_, arguments)
            table.insert(calls, arguments[3])
            if arguments[3]:match('probe%.lua$') then
                return {exit_code=0, lines={
                    'DWARFSPEC_PROBE protocol=2 core=true timeout=function'}}
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
                    'DWARFSPEC_PROBE protocol=2 core=true timeout=function'}}
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

    it('reads scheduler status without mutating a run', function()
        local run_options = options('unused-status-id')
        local scheduler = scheduler_snapshot({
            active=true,
            run_id='blocking-run',
            generation=3,
            reason='cleanup unconfirmed',
        })
        run_options.invoke = function(_, arguments)
            if arguments[3]:match('probe%.lua$') then
                return {exit_code=0, lines={
                    'DWARFSPEC_PROBE protocol=2 core=true timeout=function'}}
            end
            assert.matches('scheduler_status%.lua$', arguments[3])
            assert.equals(3, #arguments)
            return {exit_code=0,
                lines={'DWARFSPEC_JSON ' .. json.encode({
                    schema='dwarfspec.status.v1',
                    protocol=2,
                    service_loaded=true,
                    scheduler=scheduler,
                })}}
        end

        local outcome = runner.status(run_options)

        assert.equals(0, outcome.exit_code)
        assert.equals('blocking-run',
            outcome.scheduler.quarantine.run_id)
    end)

    it('lists, inspects, and reads logs through the read-only adapter',
            function()
        local run_options = options('unused-query-id')
        run_options.invoke = function(_, arguments)
            if arguments[3]:match('probe%.lua$') then
                return {exit_code=0, lines={
                    'DWARFSPEC_PROBE protocol=2 core=true timeout=function'}}
            end
            assert.matches('run_query%.lua$', arguments[3])
            local operation = arguments[4]
            if operation == 'history' then
                return {exit_code=0, lines={'DWARFSPEC_JSON ' ..
                    json.encode({
                        schema='dwarfspec.history.v1',
                        protocol=2,
                        service_loaded=true,
                        service_instance_id='service-runner-fixture',
                        runs={{
                            run_id='retained-run',
                            project_id='project-runner-fixture',
                            project_root='D:/Clients/Fixture',
                            generation=2,
                            state=RunState.PASSED,
                            terminal=true,
                            submitted_at_ms=100,
                            finished_at_ms=110,
                            cleanup_confirmed=true,
                            acknowledged=true,
                            discarded=false,
                            log_line_count=2,
                        }},
                    })}}
            elseif operation == 'show' then
                local transport = assert(json.decode(
                    report_lines('retained-run', RunState.PASSED,
                        true)[1]:sub(#'DWARFSPEC_JSON ' + 1)))
                return {exit_code=0, lines={'DWARFSPEC_JSON ' ..
                    json.encode({
                        schema='dwarfspec.run-inspection.v1',
                        protocol=2,
                        service_loaded=true,
                        found=true,
                        run_id='retained-run',
                        snapshot=transport.snapshot,
                        events=transport.events,
                        last_sequence=transport.last_sequence,
                        project_root='D:/Clients/Fixture',
                    })}}
            end
            assert.equals('logs', operation)
            return {exit_code=0, lines={'DWARFSPEC_JSON ' .. json.encode({
                schema='dwarfspec.run-logs.v1',
                protocol=2,
                service_loaded=true,
                found=true,
                service_instance_id='service-runner-fixture',
                project_id='project-runner-fixture',
                run_id='retained-run',
                generation=1,
                state=RunState.PASSED,
                lines={'START example', 'SUCCESS example'},
            })}}
        end

        local listed = runner.history(run_options)
        local inspected = runner.inspect(run_options, 'retained-run')
        local logged = runner.logs(run_options, 'retained-run')

        assert.equals(0, listed.exit_code)
        assert.equals('retained-run', listed.history.runs[1].run_id)
        assert.equals(0, inspected.exit_code)
        assert.equals(RunState.PASSED,
            inspected.inspection.snapshot.state)
        assert.equals(0, logged.exit_code)
        assert.same({'START example', 'SUCCESS example'},
            logged.logs.lines)
    end)

    it('reports missing retained runs explicitly', function()
        local run_options = options('unused-missing-id')
        run_options.invoke = function(_, arguments)
            if arguments[3]:match('probe%.lua$') then
                return {exit_code=0, lines={
                    'DWARFSPEC_PROBE protocol=2 core=true timeout=function'}}
            end
            return {exit_code=0, lines={'DWARFSPEC_JSON ' .. json.encode({
                schema='dwarfspec.run-inspection.v1',
                protocol=2,
                service_loaded=true,
                found=false,
                run_id='missing-run',
            })}}
        end

        local outcome = runner.inspect(run_options, 'missing-run')

        assert.equals(runner.exit_codes[runner.failure_kinds.HOST],
            outcome.exit_code)
        assert.equals('DwarfSpec run was not found: missing-run',
            outcome.error.message)
    end)

    it('attributes a selected path only when subprocess output emitted it', function()
        local run_options = options('emitted-selection')
        local identity = 'tests/private-emitted-selection.ds.lua'
        run_options.identities = {identity}
        run_options.invoke = function()
            return {exit_code=1, lines={'runner echoed ' .. identity}}
        end

        local outcome = runner.run(run_options)

        assert.equals(4, outcome.exit_code)
        assert.same(runner.failure_kinds.CONNECTION, outcome.error.kind)
        assert.is_truthy(outcome.error.message:find(identity, 1, true))
    end)

    it('preserves connection preflight for every auxiliary command', function()
        local cases = {
            {name='abort', invoke=function(run_options)
                return runner.abort(run_options, 'retained-run')
            end},
            {name='status', invoke=function(run_options)
                return runner.status(run_options)
            end},
            {name='history', invoke=function(run_options)
                return runner.history(run_options)
            end},
            {name='show', invoke=function(run_options)
                return runner.inspect(run_options, 'retained-run')
            end},
            {name='logs', invoke=function(run_options)
                return runner.logs(run_options, 'retained-run')
            end},
            {name='executor-recovery', invoke=function(run_options)
                return runner.recover_executor(run_options, 'retained-run', 3,
                    'operator verified clean state')
            end},
        }
        for _, case in ipairs(cases) do
            local run_options = options('command-' .. case.name)
            local calls = 0
            run_options.invoke = function()
                calls = calls + 1
                return {exit_code=7, lines={case.name .. ' probe unavailable'}}
            end

            local outcome = case.invoke(run_options)

            assert.equals(4, outcome.exit_code, case.name)
            assert.same(runner.failure_kinds.CONNECTION, outcome.error.kind,
                case.name)
            assert.is_truthy(outcome.error.message:find(
                'DFHack connection probe through "bin/dwarfspec" exited with ' ..
                    'code 7. Output: ' .. case.name .. ' probe unavailable',
                1, true), case.name)
            assert.equals(1, calls, case.name)
        end
    end)

    it('recovers one exact quarantined generation through host verification',
            function()
        local run_options = options('unused-recovery-id')
        local recovery_arguments
        run_options.invoke = function(_, arguments)
            if arguments[3]:match('probe%.lua$') then
                return {exit_code=0, lines={
                    'DWARFSPEC_PROBE protocol=2 core=true timeout=function'}}
            end
            recovery_arguments = arguments
            local lines = report_lines('blocking-run', RunState.ABORTED,
                false)
            local transport = assert(json.decode(
                lines[1]:sub(#'DWARFSPEC_JSON ' + 1)))
            transport.scheduler = scheduler_snapshot()
            return {exit_code=0,
                lines={'DWARFSPEC_JSON ' .. json.encode(transport)}}
        end

        local outcome = runner.recover_executor(run_options,
            'blocking-run', 1, 'operator verified clean state')

        assert.equals(0, outcome.exit_code)
        assert.matches('recover_executor%.lua$', recovery_arguments[3])
        assert.same({
            'blocking-run', '1', '0', 'operator verified clean state',
        }, {
            recovery_arguments[4], recovery_arguments[5],
            recovery_arguments[6], recovery_arguments[7],
        })
        assert.is_false(outcome.scheduler.quarantine.active)
    end)

    it('returns exit 5 for structured direct mutation rejections', function()
        local cases = {
            {
                name='abort',
                invoke=function(run_options)
                    return runner.abort(run_options, 'direct-run')
                end,
                response={code='invalid_run_state', operation='abort',
                    run_id='direct-run', generation=2, state='passed'},
                expected='is passed',
            },
            {
                name='recover-executor',
                invoke=function(run_options)
                    return runner.recover_executor(run_options,
                        'direct-run', 2, 'verified clean')
                end,
                response={code='clean_state_unverified',
                    operation='recover executor', run_id='direct-run',
                    generation=2, reason='owned screen remains active'},
                expected='Resolve remaining live resources',
            },
        }
        for _, case in ipairs(cases) do
            local run_options = options('direct-' .. case.name)
            run_options.invoke = function(_, arguments)
                if arguments[3]:match('probe%.lua$') then
                    return {exit_code=0, lines={
                        'DWARFSPEC_PROBE protocol=2 core=true timeout=function'}}
                end
                local response = {schema='dwarfspec.error.v1', protocol=2,
                    kind=runner.failure_kinds.HOST,
                    message='structured direct rejection'}
                for name, value in pairs(case.response) do
                    response[name] = value
                end
                return {exit_code=0, lines={
                    'DWARFSPEC_JSON ' .. json.encode(response),
                }}
            end
            local outcome = case.invoke(run_options)
            assert.equals(5, outcome.exit_code, case.name)
            assert.equals(runner.failure_kinds.HOST, outcome.error.kind)
            assert.equals(case.response.code, outcome.error.code)
            assert.matches(case.expected, outcome.error.message, 1, true)
        end
    end)

    it('appends structured acknowledgement detail to the original failure',
            function()
        local run_options = options('acknowledgement-secondary')
        run_options.invoke = function(_, arguments)
            if arguments[3]:match('probe%.lua$') then
                return {exit_code=0, lines={
                    'DWARFSPEC_PROBE protocol=2 core=true timeout=function'}}
            elseif arguments[3]:match('bootstrap%.lua$') then
                return {exit_code=0, lines=transport_lines(arguments,
                    run_options.run_id, RunState.STARTING, false)}
            elseif arguments[3]:match('status%.lua$') then
                return {exit_code=0, lines=transport_lines(arguments,
                    run_options.run_id, RunState.FAILED, true)}
            end
            assert.matches('acknowledge%.lua$', arguments[3])
            return {exit_code=0, lines={'DWARFSPEC_JSON ' .. json.encode({
                schema='dwarfspec.error.v1', protocol=2,
                kind=runner.failure_kinds.HOST,
                code='owner_capability_rejected',
                message='owner rejected', operation='acknowledgement',
                run_id=run_options.run_id, generation=1, state='failed',
            })}}
        end
        local outcome = runner.run(run_options)
        assert.equals(runner.failure_kinds.TEST, outcome.error.kind)
        assert.equals(6, outcome.exit_code)
        assert.matches('could not acknowledge terminal result:',
            outcome.error.message, 1, true)
        assert.matches('owning DwarfSpec process', outcome.error.message,
            1, true)
        assert.is_falsy(outcome.error.message:find('table:', 1, true))
    end)
end)
