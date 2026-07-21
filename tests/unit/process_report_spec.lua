-- Unit contracts for cross-platform commands and native JSON reports.

local process = require('dwarfspec.process')
local report = require('dwarfspec.report')

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
        local environment = {
            getenv=function(name) return variables[name] end,
        }

        assert.equals(explicit, process.resolve_runner({
            runner=explicit, platform='unix'}, environment))
        assert.equals(root .. '/dfhack-run', process.resolve_runner({
            platform='unix'}, environment))
        variables.DFHACK_RUNNER = nil
        assert.equals(root .. '/dfhack-run', process.resolve_runner({
            platform='unix'}, environment))
        variables.DFHACK_ROOT = nil
        assert.equals(path_root .. '/dfhack-run', process.resolve_runner({
            platform='unix'}, environment))
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
                local file = io.open(path:gsub('\\', '/'), 'rb')
                if not file then return false end
                file:close()
                return true
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
    it('uses the last canonical JSON line and extracts progress', function()
        local lines = {
            'DWARFSPEC_JSON {"protocol":1,"run_id":"old"}',
            'OUTPUT 1 START suite example',
            'OUTPUT 2 SUCCESS suite example',
            'DWARFSPEC_JSON final',
        }
        local parsed = report.parse(lines, 'run', function(text)
            assert.equals('final', text)
            return {
                schema='dwarfspec.run.v1',
                protocol=1,
                run_id='run',
                state='passed',
                terminal=true,
                generation=1,
                counts={},
                totals={},
                output_count=2,
                cleanup_confirmed=true,
                failures={},
            }
        end)
        assert.equals('passed', parsed.state)
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
                    state='passed',
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
                    state='passed',
                    terminal=true,
                    generation=1,
                    counts={}, totals={}, output_count=0,
                    cleanup_confirmed=true, failures={},
                }
            end)
        end, 'unsupported DwarfSpec report schema: another.schema')
    end)
end)
