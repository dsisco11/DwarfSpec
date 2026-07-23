-- Unit contracts for external orchestration, recovery, and exit propagation.

local json = require('dkjson')
local runner = require('dwarfspec.runner')

---Builds one canonical native report output line.
---@param run_id string
---@param state string
---@param cleanup_confirmed boolean
---@param output_count integer|nil
---@return string[]
local function report_lines(run_id, state, cleanup_confirmed, output_count)
    local terminal = state == 'passed' or state == 'failed' or
        state == 'aborted'
    local lines = {}
    if output_count then table.insert(lines, 'OUTPUT 1 progress line') end
    table.insert(lines, 'DWARFSPEC_JSON ' .. json.encode({
            schema='dwarfspec.run.v1',
            protocol=1,
            run_id=run_id,
            state=state,
            terminal=terminal,
            generation=1,
            counts={successes=state == 'passed' and 1 or 0,
                failures=state == 'failed' and 1 or 0, errors=0, pending=0},
            totals={successes=state == 'passed' and 1 or 0,
                failures=state == 'failed' and 1 or 0, errors=0, pending=0},
            output_count=output_count or 0,
            cleanup_confirmed=cleanup_confirmed,
            failures={},
        }))
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
        poll_interval_ms=1,
        startup_delay_frames=1,
        lease_timeout_ms=5000,
        lease_check_frames=30,
        result_directory=false,
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
                    lines=report_lines('pass-run', 'starting', false)}
            end
            return {exit_code=0,
                lines=report_lines('pass-run', 'passed', true, 1)}
        end

        local outcome = runner.run(run_options)

        assert.equals(0, outcome.exit_code)
        assert.equals('passed', outcome.report.state)
        assert.same({'progress line'}, emitted)
        assert.equals(3, calls)
        local test_glob_found = false
        local lua_module_root_found = false
        for _, argument in ipairs(bootstrap_arguments) do
            if argument == '--test-glob=tests/automation/*.lua' then
                test_glob_found = true
            end
            if argument:match('^%-%-lua%-module%-root=') then
                lua_module_root_found = true
            end
        end
        assert.is_true(test_glob_found)
        assert.is_true(lua_module_root_found)
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
                lines=report_lines('failed-run', 'failed', true)}
        end
        local outcome = runner.run(run_options)
        assert.equals(runner.exit_codes.test, outcome.exit_code)
        assert.matches('finished with state failed', outcome.error.message,
            1, true)
        assert.equals(2, #calls)
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
                    lines=report_lines('timeout-run', 'starting', false)}
            end
            return {exit_code=0,
                lines=report_lines('timeout-run', 'aborted', true)}
        end
        local outcome = runner.run(run_options)
        assert.equals(runner.exit_codes.timeout, outcome.exit_code)
        assert.equals('aborted', outcome.report.state)
        assert.matches('abort%.lua$', calls[#calls])
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
                    lines=report_lines('malformed-run', 'starting', false)}
            elseif arguments[3]:match('status%.lua$') then
                status_seen = true
                return {exit_code=0, lines={'not json'}}
            end
            return {exit_code=0,
                lines=report_lines('malformed-run', 'aborted', true)}
        end
        local outcome = runner.run(run_options)
        assert.is_true(status_seen)
        assert.equals(runner.exit_codes.host, outcome.exit_code)
        assert.equals('aborted', outcome.report.state)
        assert.matches('did not contain a DWARFSPEC_JSON report',
            outcome.error.message, 1, true)
    end)

    it('returns a connection failure before bootstrap', function()
        local run_options = options('connection-run')
        run_options.invoke = function()
            return {exit_code=1, lines={'not running'}}
        end
        local outcome = runner.run(run_options)
        assert.equals(runner.exit_codes.connection, outcome.exit_code)
        assert.matches('DFHack is not running', outcome.error.message,
            1, true)
        assert.is_nil(outcome.report)
    end)

    it('classifies a missing configured runner as a dependency failure',
            function()
        local run_options = options('missing-runner')
        run_options.runner = 'tests/framework/runner_path/missing'
        local outcome = runner.run(run_options)
        assert.equals(runner.exit_codes.dependency, outcome.exit_code)
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
        assert.equals(runner.exit_codes.connection, outcome.exit_code)
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
                    lines=report_lines('interrupted-run', 'starting', false)}
            end
            return {exit_code=0,
                lines=report_lines('interrupted-run', 'aborted', true)}
        end
        local outcome = runner.run(run_options)
        assert.equals(runner.exit_codes.aborted, outcome.exit_code)
        assert.equals('DwarfSpec run interrupted', outcome.error.message)
        assert.equals('aborted', outcome.report.state)
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
                lines=report_lines('unclean-run', 'passed', false)}
        end
        local outcome = runner.run(run_options)
        assert.equals(runner.exit_codes.test, outcome.exit_code)
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
                lines=report_lines('explicit-abort', 'aborted', true)}
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
                lines=report_lines('bootstrap-failure', 'aborted', true)}
        end
        local outcome = runner.run(run_options)
        assert.equals(runner.exit_codes.host, outcome.exit_code)
        assert.matches('bootstrap exited with 9', outcome.error.message,
            1, true)
        assert.equals('aborted', outcome.report.state)
    end)

    it('classifies status transport failure and recovers cleanup', function()
        local run_options = options('status-failure')
        run_options.invoke = function(_, arguments)
            if arguments[3]:match('probe%.lua$') then
                return {exit_code=0, lines={
                    'DWARFSPEC_PROBE protocol=1 core=true timeout=function'}}
            elseif arguments[3]:match('bootstrap%.lua$') then
                return {exit_code=0,
                    lines=report_lines('status-failure', 'starting', false)}
            elseif arguments[3]:match('status%.lua$') then
                return {exit_code=11, lines={'status failed'}}
            end
            return {exit_code=0,
                lines=report_lines('status-failure', 'aborted', true)}
        end
        local outcome = runner.run(run_options)
        assert.equals(runner.exit_codes.host, outcome.exit_code)
        assert.matches('status exited with 11', outcome.error.message,
            1, true)
        assert.equals('aborted', outcome.report.state)
    end)

    it('propagates a host-reported abort with its stable exit code', function()
        local run_options = options('host-aborted')
        run_options.invoke = function(_, arguments)
            if arguments[3]:match('probe%.lua$') then
                return {exit_code=0, lines={
                    'DWARFSPEC_PROBE protocol=1 core=true timeout=function'}}
            end
            return {exit_code=0,
                lines=report_lines('host-aborted', 'aborted', true)}
        end
        local outcome = runner.run(run_options)
        assert.equals(runner.exit_codes.aborted, outcome.exit_code)
        assert.equals('aborted', outcome.report.state)
    end)

    it('reports result persistence failures after a passing native run',
            function()
        local run_options = options('write-failure')
        run_options.result_directory = require('lfs').currentdir() ..
            '/tests/unit/runner_spec.lua'
        run_options.invoke = function(_, arguments)
            if arguments[3]:match('probe%.lua$') then
                return {exit_code=0, lines={
                    'DWARFSPEC_PROBE protocol=1 core=true timeout=function'}}
            end
            return {exit_code=0,
                lines=report_lines('write-failure', 'passed', true)}
        end
        local outcome = runner.run(run_options)
        assert.equals(runner.exit_codes.host, outcome.exit_code)
        assert.matches('could not create directory', outcome.error.message,
            1, true)
    end)

    it('writes the version 1 report under a run-named directory result',
            function()
        local lfs = require('lfs')
        local result_directory = lfs.currentdir() ..
            '/tests/framework/command_project/' ..
            '.test-results/legacy-result-contract'
        local result_path = result_directory .. '/legacy-result.json'
        os.remove(result_path)
        lfs.rmdir(result_directory)

        local run_options = options('legacy-result')
        run_options.result_directory = result_directory
        run_options.invoke = function(_, arguments)
            if arguments[3]:match('probe%.lua$') then
                return {exit_code=0, lines={
                    'DWARFSPEC_PROBE protocol=1 core=true timeout=function'}}
            end
            return {exit_code=0,
                lines=report_lines('legacy-result', 'passed', true)}
        end

        local outcome = runner.run(run_options)
        local file = assert(io.open(result_path, 'rb'))
        local contents = assert(file:read('*a'))
        file:close()
        assert(os.remove(result_path))
        assert(lfs.rmdir(result_directory))
        local persisted = assert(json.decode(contents))

        assert.equals(runner.exit_codes.success, outcome.exit_code)
        assert.equals('dwarfspec.run.v1', persisted.schema)
        assert.equals('legacy-result', persisted.run_id)
        assert.equals('passed', persisted.state)
    end)
end)
