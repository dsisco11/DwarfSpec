-- Unit contracts for cross-platform commands and native JSON reports.

local process = require('dwarfspec.process')
local report = require('dwarfspec.report')
local EComparison =
    require('dwarfspec.automation.base_screen_focus_comparisons')
local RunState = require('dwarfspec.automation.run_states')

---Reads one version 2 checked-in contract fixture.
---@param name string
---@return string
local function read_contract_fixture(name)
    local file = assert(io.open(
        'tests/framework/fixtures/service_v2/' .. name, 'rb'))
    local contents = assert(file:read('*a'))
    file:close()
    return contents
end

describe('DwarfSpec process bridge', function()
    it('quotes Windows and Unix-like arguments with spaces and metacharacters',
            function()
        assert.equals('"path with spaces\\runner.exe"',
            process.quote('path with spaces\\runner.exe', 'windows'))
        assert.equals("'path with spaces/runner'",
            process.quote('path with spaces/runner', 'unix'))
        assert.equals("'it'\\''s'", process.quote("it's", 'unix'))
        assert.matches('"value&still one argument"',
            process.command('runner', {'value&still one argument'}, 'windows'),
            1, true)
    end)

    it('normalizes child-process output and nonzero status', function()
        local received
        local fake_pipe = {
            lines=function()
                local values = {'first', 'second'}
                local index = 0
                return function()
                    index = index + 1
                    return values[index]
                end
            end,
            close=function() return nil, 'exit', 9 end,
        }
        local result = process.invoke('runner', {'one'}, {
            platform='unix',
            popen=function(command)
                received = command
                return fake_pipe
            end,
        })
        assert.same({'first', 'second'}, result.lines)
        assert.equals(9, result.exit_code)
        assert.equals("'runner' 'one' 2>&1", received)
    end)

    it('resolves every documented runner source in priority order', function()
        local root = 'tests/framework/runner_root'
        local path_root = 'tests/framework/runner_path'
        local explicit = path_root .. '/dfhack-run'
        local variables = {
            DFHACK_RUNNER=root .. '/dfhack-run',
            DFHACK_ROOT=root,
            PATH=path_root,
        }
        local existing = {
            [root .. '/dfhack-run']=true,
            [path_root .. '/dfhack-run']=true,
        }
        local environment = {
            getenv=function(name) return variables[name] end,
        }
        local options = {
            platform='unix',
            isfile=function(path) return existing[path] == true end,
        }

        options.runner = explicit
        assert.equals(explicit, process.resolve_runner(options, environment))
        options.runner = nil
        assert.equals(root .. '/dfhack-run',
            process.resolve_runner(options, environment))
        variables.DFHACK_RUNNER = nil
        assert.equals(root .. '/dfhack-run',
            process.resolve_runner(options, environment))
        variables.DFHACK_ROOT = nil
        assert.equals(path_root .. '/dfhack-run',
            process.resolve_runner(options, environment))
    end)

    it('resolves Windows DFHACK_ROOT and reports an actionable miss', function()
        local environment = {
            getenv=function(name)
                if name == 'DFHACK_ROOT' then
                    return 'tests\\framework\\runner_root'
                end
                return ''
            end,
        }
        local options = {
            platform='windows',
            isfile=function(path)
                return path ==
                    'tests\\framework\\runner_root\\dfhack-run.exe'
            end,
        }
        assert.equals('tests\\framework\\runner_root\\dfhack-run.exe',
            process.resolve_runner(options, environment))
        assert.has_error(function()
            process.resolve_runner({
                platform='windows',
                isfile=function() return false end,
            }, environment)
        end, 'DFHACK_ROOT does not contain dfhack-run: ' ..
            'tests\\framework\\runner_root')
        assert.has_error(function()
            process.resolve_runner({platform='unix'}, {
                getenv=function() return '' end,
            })
        end, 'could not find dfhack-run; set DFHACK_RUNNER, set DFHACK_ROOT, or add dfhack-run to PATH')
    end)
end)

describe('DwarfSpec native reports', function()
    ---Returns one detached observation for report-format fixtures.
    ---@param available boolean
    ---@return table
    local function focus_details(available)
        return {
            screen={status='present', type='viewscreen_dwarfmodest'},
            focus=available and {
                status='available',
                values={'dwarfmode/Default'},
            } or {
                status='unavailable',
                values={},
                error='focus capture failed',
            },
        }
    end

    ---Returns one diagnostic event for report-format fixtures.
    ---@param scope 'example'|'suite'
    ---@param incomplete boolean
    ---@param kind string|nil
    ---@return table
    local function focus_event(scope, incomplete, kind)
        kind = kind or 'base_screen_focus_changed'
        local changed = kind == 'base_screen_focus_changed'
        local content = {
            severity=changed and 'warning' or 'info',
            scope=scope,
            attribution=scope == 'suite' and 'file' or 'test',
            suite_name='tests/focus_spec.lua',
            source_identity='tests/focus_spec.lua',
            repeat_index=1,
            screen_comparison=changed and EComparison.CHANGED or
                EComparison.SAME,
            focus_comparison=incomplete and EComparison.UNAVAILABLE or
                EComparison.SAME,
            details_complete=not incomplete,
            before=focus_details(not incomplete),
            after=focus_details(not incomplete),
        }
        if scope == 'example' then
            content.example_name='focus suite changes focus'
        end
        return {
            type='diagnostic.recorded',
            payload={kind=kind, content=content},
        }
    end

    it('formats an unloaded service status without requiring a scheduler',
            function()
        local status = report.parse_status({'DWARFSPEC_JSON ignored'},
            function()
                return {
                    schema='dwarfspec.status.v1',
                    protocol=2,
                    service_loaded=false,
                }
            end)

        assert.same({'SERVICE not loaded'}, report.format_status(status))
    end)

    it('formats executor quarantine as an actionable blocked state',
            function()
        assert.same({
            'EXECUTOR_QUARANTINED: run run-blocking-1 generation 6 left ' ..
                'cleanup unconfirmed: external runner recovery. This run ' ..
                'remains queued; press Ctrl+C and restart DFHack after ' ..
                'confirming no live run is active',
        }, report.format_events({
            {
                type='scheduler.blocked',
                payload={
                    kind='executor_quarantined',
                    reason='external runner recovery',
                    blocking_run_id='run-blocking-1',
                    blocking_generation=6,
                },
            },
        }))
    end)

    it('formats example warnings after their test result', function()
        local lines = report.format_events({
            {
                type='test.finished',
                payload={
                    name='focus suite changes focus',
                    status='success',
                    duration_ms=4,
                },
            },
            focus_event('example', false),
        })

        assert.same({
            'SUCCESS focus suite changes focus (4 ms)',
            'WARNING base-screen focus changed after example focus suite ' ..
                'changes focus in tests/focus_spec.lua (repeat=1 ' ..
                'attribution=test screen=changed focus=same complete=true)',
        }, lines)
    end)

    it('formats suite warnings after file activity with incomplete details',
            function()
        local lines = report.format_events({
            {type='repeat.started', payload={
                repeat_index=1, repeat_count=1}},
            focus_event('suite', true),
        })

        assert.same({
            'RUN 1/1',
            'WARNING base-screen focus changed after suite ' ..
                'tests/focus_spec.lua (repeat=1 attribution=file ' ..
                'screen=changed focus=unavailable complete=false)',
        }, lines)
    end)

    it('does not format incomplete verification as a warning', function()
        assert.same({}, report.format_events({
            focus_event('example', true,
                'base_screen_focus_verification_incomplete'),
        }))
    end)

    it('returns a canonical adapter rejection separately from transport',
            function()
        local transport, _, response_error =
            report.parse_transport_response({'DWARFSPEC_JSON ignored'}, {
                run_id='rejected-run',
                after_sequence=0,
            }, function()
                return {
                    schema='dwarfspec.error.v1',
                    protocol=2,
                    kind='registration',
                    message='incompatible automation package version: ' ..
                        'expected 0.1.3, found 0.2.0',
                }
            end)

        assert.is_nil(transport)
        assert.equals('registration', response_error.kind)
        assert.equals('incompatible automation package version: ' ..
            'expected 0.1.3, found 0.2.0', response_error.message)
    end)

    it('accepts one exact version 2 transport identity and cursor', function()
        local payload = read_contract_fixture('transport_failed.json')
        local transport = report.parse_transport({
            'diagnostic output',
            'DWARFSPEC_JSON ' .. payload,
        }, {
            service_instance_id='service-fixture-1',
            project_id='project-alpha',
            run_id='run-failed',
            generation=4,
            after_sequence=0,
        })

        assert.equals('dwarfspec.transport.v2', transport.schema)
        assert.equals(RunState.FAILED, transport.snapshot.state)
        assert.equals(1, transport.last_sequence)
    end)

    it('rejects duplicated canonical JSON', function()
        local lines = {
            'DWARFSPEC_JSON first',
            'DWARFSPEC_JSON final',
        }
        assert.has_error(function()
            report.parse_transport(lines, {after_sequence=0})
        end, 'DFHack output contained 2 DWARFSPEC_JSON reports; expected one')
    end)

    it('rejects missing and unsupported reports', function()
        assert.has_error(function()
            report.parse_transport({}, {after_sequence=0})
        end,
            'DFHack output did not contain a DWARFSPEC_JSON report')
        assert.has_error(function()
            report.parse_transport({'DWARFSPEC_JSON ignored'}, {
                after_sequence=0,
            }, function()
                return {
                    schema='dwarfspec.run.v1',
                    protocol=1,
                }
            end)
        end, 'unsupported DwarfSpec report schema: dwarfspec.run.v1')
        assert.has_error(function()
            report.parse_transport({'DWARFSPEC_JSON ignored'}, {
                after_sequence=0,
            }, function()
                return {
                    schema='another.schema',
                    protocol=2,
                }
            end)
        end, 'unsupported DwarfSpec report schema: another.schema')
    end)

    it('accepts and validates version 2 transport identities', function()
        local contents = read_contract_fixture('transport_failed.json')
        local parsed = report.parse_transport(
            {'DWARFSPEC_JSON ' .. contents}, {
                service_instance_id='service-fixture-1',
                project_id='project-alpha',
                run_id='run-failed',
                generation=4,
                after_sequence=0,
            })

        assert.equals('dwarfspec.transport.v2', parsed.schema)
        assert.equals(RunState.FAILED,
            parsed.snapshot.state)
        assert.has_error(function()
            report.parse_transport({'DWARFSPEC_JSON ' .. contents}, {
                run_id='foreign-run',
                after_sequence=0,
            })
        end, 'automation transport identity mismatch: run_id')
    end)

    it('validates version 2 result fixtures', function()
        local contents = read_contract_fixture('result_passed.json')
        local value, _, decode_error = require('dkjson').decode(contents)
        assert(value, decode_error)
        assert.equals(value, report.validate_result(value))
        assert.equals('base_screen_focus_changed',
            value.events[1].payload.kind)
        assert.is_nil(contents:find('0x', 1, true))
    end)

    it('formats every inspected event with its sequence and payload',
            function()
        local contents = read_contract_fixture('transport_failed.json')
        local transport = report.parse_transport({
            'DWARFSPEC_JSON ' .. contents,
        }, {
            after_sequence=0,
        })
        local inspection = {
            schema='dwarfspec.run-inspection.v1',
            protocol=2,
            service_loaded=true,
            found=true,
            run_id=transport.run_id,
            snapshot=transport.snapshot,
            events=transport.events,
            last_sequence=transport.last_sequence,
        }

        local lines = report.format_run_inspection(inspection)

        assert.equals('EVENTS ' .. tostring(#transport.events),
            lines[6])
        assert.matches('^EVENT 1 ', lines[7])
        assert.matches('"', lines[7], 1, true)
    end)
end)
