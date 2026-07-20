-- Unit contracts for live automation ownership and generation guards.

local host_path = 'tests/automation/support/busted_host.lua'

describe('automation host ownership', function()
    local original_dfhack
    local callbacks
    local active_callbacks
    local tick
    local host

    before_each(function()
        original_dfhack = rawget(_G, 'dfhack')
        callbacks = {}
        active_callbacks = {}
        tick = 0
        rawset(_G, 'dfhack', {
            is_core_context=true,
        })

        ---Returns a deterministic monotonic unit-test tick.
        ---@return integer
        function dfhack.getTickCount()
            tick = tick + 1
            return tick
        end

        ---Captures one fake frame callback without executing it.
        ---@param delay integer
        ---@param mode string
        ---@param callback function
        ---@return integer
        function dfhack.timeout(delay, mode, callback)
            assert.equals('frames', mode)
            assert.is_true(delay >= 1)
            local id = #callbacks + 1
            callbacks[id] = callback
            active_callbacks[id] = callback
            return id
        end

        ---Returns, replaces, or cancels an active fake callback.
        ---@param id integer
        ---@param replacement function|nil
        ---@return function|nil
        function dfhack.timeout_active(id, replacement)
            local callback = active_callbacks[id]
            active_callbacks[id] = replacement
            return callback
        end

        host = assert(loadfile(host_path))()
    end)

    after_each(function()
        rawset(_G, 'dfhack', original_dfhack)
    end)

    ---Returns the smallest valid queued-run option set.
    ---@param run_id string
    ---@return table
    local function options(run_id)
        return {
            run_id=run_id,
            filters={},
            filter_out={},
            names={},
            tags={},
            exclude_tags={},
            repeat_count=1,
            seed=1,
            spec=nil,
            defer_frames=1,
            lease_timeout_ms=10000,
            lease_check_frames=1,
        }
    end

    it('rejects overlap and ignores a callback after abort', function()
        local run = host.start('.', '.', options('owner'))
        assert.equals('starting', run.state)
        assert.has_error(function()
            host.start('.', '.', options('overlap'))
        end, 'automation run owner is already starting')

        local cleaned = false
        run.cleanup_module.push(run.cleanup_registry, 'abort proof', function()
            cleaned = true
        end)
        local aborted = host.abort('owner')
        assert.equals('aborted', aborted.state)
        assert.is_nil(active_callbacks[1])
        assert.is_nil(active_callbacks[2])
        assert.is_true(cleaned)
        assert.is_true(aborted.cleanup_confirmed)
        callbacks[1]()
        callbacks[2]()
        assert.equals('aborted', aborted.state)
        assert.equals(aborted, host.find('owner'))
    end)

    it('retains an unobserved result until its owner acknowledges it', function()
        local aborted = host.abort(host.start(
            '.',
            '.', options('retained')).run_id)
        assert.has_error(function()
            host.start('.', '.', options('replacement'))
        end, 'automation run retained has an unobserved aborted result')

        aborted.terminal_observed = true
        local replacement = host.start('.', '.', options('replacement'))
        assert.equals('starting', replacement.state)
        host.abort(replacement.run_id)
    end)

    it('expires an unpolled lease and performs emergency cleanup', function()
        local lease_options = options('lease-owner')
        lease_options.lease_timeout_ms = 10
        local run = host.start('.', '.', lease_options)
        local cleaned = false
        run.cleanup_module.push(run.cleanup_registry, 'lease proof', function()
            cleaned = true
        end)

        tick = 100
        callbacks[2]()

        assert.equals('aborted', run.state)
        assert.is_true(cleaned)
        assert.is_true(run.cleanup_confirmed)
        assert.matches('status lease expired', run.output_lines[1], 1, true)
        assert.is_nil(active_callbacks[1])
    end)

    it('builds a complete JSON-safe report for PowerShell consumption', function()
        local report = host.report_data({
            protocol_version=1,
            run_id='json-run',
            state='failed',
            generation=7,
            counts={successes=1, failures=1, errors=0, pending=0},
            totals={successes=1, failures=1, errors=0, pending=0},
            current_test='suite "quoted"',
            output_lines={'one'},
            cleanup_confirmed=true,
            cleanup_reason='suite completion',
            host_error=nil,
            host_trace=nil,
            failure_details={{
                kind='failure',
                name='suite "quoted"',
                message='line one\nline two',
                trace=nil,
            }},
        })

        assert.equals(1, report.protocol)
        assert.equals('json-run', report.run_id)
        assert.is_true(report.terminal)
        assert.equals('suite "quoted"', report.current_test)
        assert.equals('line one\nline two', report.failures[1].message)
        assert.equals('\0', report.failures[1].trace)
        assert.is_true(report.cleanup_confirmed)
    end)

    it('normalizes Busted filters and discovers only approved live specs',
            function()
        local filters = host.filter_options({
            tags='fast',
            exclude_tags={'slow'},
            filter='tooltip',
            names={'one'},
            filter_out='legacy',
        })
        local received_roots
        local received_patterns
        local received_options
        local discovered = host.discover_tests('repository',
            function(roots, patterns, options)
                received_roots = roots
                received_patterns = patterns
                received_options = options
                return {'tooltip_spec.ds.lua'}
            end, 'tooltip_spec.ds.lua')

        assert.same({'fast'}, filters.tags)
        assert.same({'slow'}, filters.excludeTags)
        assert.same({'tooltip'}, filters.filter)
        assert.same({'one'}, filters.name)
        assert.same({'legacy'}, filters.filterOut)
        assert.same({'tooltip_spec.ds.lua'}, discovered)
        assert.matches('repository[/\\]tests[/\\]tooltip_spec%.ds%.lua$',
            received_roots[1])
        assert.same({'_spec%.ds%.lua$'}, received_patterns)
        assert.is_true(received_options.recursive)
        assert.has_error(function()
            host.discover_tests('repository', function() end,
                '../outside_spec.ds.lua')
        end, 'live spec must name one project-relative *_spec.ds.lua path')
    end)

    it('rejects unsafe host run identifiers before scheduling work', function()
        assert.has_error(function()
            host.start('.', '.', options('../unsafe'))
        end, 'run id must contain only letters, digits, dot, underscore, or dash')
        assert.equals(0, #callbacks)
    end)

    it('installs ds reset hooks around every Busted example', function()
        local hooks = {}
        local reset_count = 0
        local busted = {
            api={
                before_each=function(callback)
                    hooks.before_each = callback
                end,
                after_each=function(callback)
                    hooks.after_each = callback
                end,
            },
        }

        host.install_ds_lifecycle(busted, {
            reset=function()
                reset_count = reset_count + 1
            end,
        })
        hooks.before_each()
        hooks.after_each()

        assert.equals(2, reset_count)
    end)
end)
