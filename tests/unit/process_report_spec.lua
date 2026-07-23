-- Unit contracts for cross-platform commands and native JSON reports.

local process = require('dwarfspec.process')
local report = require('dwarfspec.report')
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

    it('does not accept a transitional version 1 report as transport',
            function()
        assert.has_error(function()
            report.parse_transport({'DWARFSPEC_JSON ignored'}, 'run',
                function()
                    return {
                        schema='dwarfspec.run.v1',
                        protocol=1,
                        run_id='run',
                        state=RunState.PASSED,
                        terminal=true,
                        generation=1,
                        counts={},
                        totals={},
                        output_count=0,
                        cleanup_confirmed=true,
                        failures={},
                    }
                end)
        end, 'DFHack output did not contain version 2 transport data')
    end)

    it('rejects duplicated canonical JSON and extracts diagnostics', function()
        local lines = {
            'DWARFSPEC_JSON {"protocol":1,"run_id":"old"}',
            'OUTPUT 1 START suite example',
            'OUTPUT 2 SUCCESS suite example',
            'DWARFSPEC_JSON final',
        }
        assert.has_error(function()
            report.parse(lines, 'run')
        end, 'DFHack output contained 2 DWARFSPEC_JSON reports; expected one')
        assert.same({'START suite example', 'SUCCESS suite example'},
            report.progress(lines))
    end)

    it('rejects malformed and foreign reports', function()
        assert.has_error(function() report.parse({}, 'run') end,
            'DFHack output did not contain a DWARFSPEC_JSON report')
        assert.has_error(function()
            report.parse({'DWARFSPEC_JSON ignored'}, 'run', function()
                return {
                    schema='dwarfspec.run.v1',
                    protocol=1,
                    run_id='other',
            state=RunState.PASSED,
                    terminal=true,
                    generation=1,
                    counts={}, totals={}, output_count=0,
                    cleanup_confirmed=true, failures={},
                }
            end)
        end, 'DwarfSpec report run id "other" does not match "run"')
    end)

    it('rejects foreign report schemas', function()
        assert.has_error(function()
            report.parse({'DWARFSPEC_JSON ignored'}, 'run', function()
                return {
                    schema='another.schema',
                    protocol=1,
                    run_id='run',
            state=RunState.PASSED,
                    terminal=true,
                    generation=1,
                    counts={}, totals={}, output_count=0,
                    cleanup_confirmed=true, failures={},
                }
            end)
        end, 'unsupported DwarfSpec report schema: another.schema')
    end)

    it('accepts and validates version 2 transport identities', function()
        local contents = read_contract_fixture('transport_failed.json')
        local parsed = report.parse(
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
            report.parse({'DWARFSPEC_JSON ' .. contents}, {
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
    end)
end)
