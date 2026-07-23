-- Unit contracts for live automation ownership and generation guards.

local host_path = 'tests/automation/support/busted_host.lua'
local RunState = require('dwarfspec.automation.run_states')

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
            specs={},
            defer_frames=1,
            lease_timeout_ms=10000,
            lease_check_frames=1,
        }
    end

    it('initializes and retains the version 1 singleton registry shape',
            function()
        assert.is_nil(dfhack.dwarfspec)

        local run = host.start('.', '.', options('registry-contract'))
        local registry = dfhack.dwarfspec

        assert.equals(1, registry.protocol_version)
        assert.equals(1, registry.generation)
        assert.equals(run, registry.active_run)
        assert.is_nil(registry.last_completed)

        local aborted = host.abort(run.run_id)
        assert.is_nil(registry.active_run)
        assert.equals(aborted, registry.last_completed)
        assert.is_false(aborted.terminal_observed)

        assert.equals(aborted, host.poll(run.run_id))
        assert.is_true(aborted.terminal_observed)
    end)

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
        run.mount_cleanup_probe = function()
            return {
                current_mount_id=nil,
                active_screen_count=cleaned and 0 or 1,
                tracked_screen_count=1,
                subject_count=cleaned and 0 or 1,
                pointer_active=not cleaned,
            }
        end
        local aborted = host.abort('owner')
        assert.equals('aborted', aborted.state)
        assert.is_nil(active_callbacks[1])
        assert.is_nil(active_callbacks[2])
        assert.is_true(cleaned)
        assert.is_true(aborted.cleanup_confirmed)
        assert.is_true(aborted.mount_cleanup_state.verified)
        assert.equals(0, aborted.mount_cleanup_state.active_screen_count)
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
        run.mount_cleanup_probe = function()
            return {
                current_mount_id=nil,
                active_screen_count=cleaned and 0 or 1,
                tracked_screen_count=1,
                subject_count=cleaned and 0 or 1,
                pointer_active=not cleaned,
            }
        end

        tick = 100
        callbacks[2]()

        assert.equals('aborted', run.state)
        assert.is_true(cleaned)
        assert.is_true(run.cleanup_confirmed)
        assert.is_true(run.mount_cleanup_state.verified)
        assert.matches('status lease expired', run.output_lines[1], 1, true)
        assert.is_nil(active_callbacks[1])
    end)

    it('refuses cleanup confirmation while an owned screen remains active',
            function()
        local run = host.start('.', '.', options('active-screen'))
        run.mount_cleanup_probe = function()
            return {
                current_mount_id=1,
                active_screen_count=1,
                tracked_screen_count=1,
                subject_count=1,
                pointer_active=true,
            }
        end

        local aborted = host.abort(run.run_id)

        assert.is_false(aborted.cleanup_confirmed)
        assert.equals(1, aborted.totals.errors)
        assert.is_false(aborted.mount_cleanup_state.verified)
        assert.equals(1, aborted.mount_cleanup_state.active_screen_count)
        assert.matches('mount lifecycle verification failed',
            aborted.failure_details[1].message, 1, true)
    end)

    it('never confirms cleanup after an earlier cleanup action failed',
            function()
        local run = host.start('.', '.', options('cleanup-failure'))
        local restored = false
        run.cleanup_module.push(run.cleanup_registry, 'restoration', function()
            restored = true
        end)
        run.cleanup_module.push(run.cleanup_registry, 'broken cleanup',
            function()
                error('cleanup exploded')
            end)

        local aborted = host.abort(run.run_id)

        assert.equals('aborted', aborted.state)
        assert.is_true(restored)
        assert.is_false(aborted.cleanup_confirmed)
        assert.equals(1, aborted.totals.errors)
        assert.equals(0, aborted.cleanup_module.pending_count(
            aborted.cleanup_registry))
        assert.matches('cleanup broken cleanup failed during by request',
            aborted.failure_details[1].message, 1, true)
        assert.matches('cleanup exploded', aborted.failure_details[1].message,
            1, true)
    end)

    it('builds a complete JSON-safe report for PowerShell consumption', function()
        local report = host.report_data({
            protocol_version=1,
            run_id='json-run',
            state=RunState.FAILED,
            generation=7,
            counts={successes=1, failures=1, errors=0, pending=0},
            totals={successes=1, failures=1, errors=0, pending=0},
            current_test='suite "quoted"',
            output_lines={'one'},
            cleanup_confirmed=true,
            cleanup_reason='suite completion',
            mount_cleanup_state={
                active_screen_count=0,
                tracked_screen_count=1,
                subject_count=0,
                pointer_active=false,
                verified=true,
            },
            host_error=nil,
            host_trace=nil,
            failure_details={{
                kind='failure',
                name='suite "quoted"',
                message='line one\nline two',
                trace=nil,
            }},
        })

        assert.equals('dwarfspec.run.v1', report.schema)
        assert.equals(1, report.protocol)
        assert.equals('json-run', report.run_id)
        assert.is_true(report.terminal)
        assert.equals('suite "quoted"', report.current_test)
        assert.equals('line one\nline two', report.failures[1].message)
        assert.equals('\0', report.failures[1].trace)
        assert.is_true(report.cleanup_confirmed)
        assert.is_true(report.mount_cleanup_state.verified)
    end)

    it('normalizes filters and loads exact safe externally selected specs',
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
                return {'tooltip check.ds.lua'}
            end, {'tooltip check.ds.lua'})

        assert.same({'fast'}, filters.tags)
        assert.same({'slow'}, filters.excludeTags)
        assert.same({'tooltip'}, filters.filter)
        assert.same({'one'}, filters.name)
        assert.same({'legacy'}, filters.filterOut)
        assert.same({'tooltip check.ds.lua'}, discovered)
        assert.matches('repository[/\\]tests[/\\]tooltip check%.ds%.lua$',
            received_roots[1])
        assert.same({'%.lua$'}, received_patterns)
        assert.is_true(received_options.recursive)
        assert.has_error(function()
            host.discover_tests('repository', function() end,
                {'../outside.lua'})
        end, 'live spec must name one safe project-relative Lua path')

        assert.has_error(function()
            host.discover_tests('repository', function() return {} end)
        end, 'no live specs were selected')
    end)

    it('rejects unsafe host run identifiers before scheduling work', function()
        assert.has_error(function()
            host.start('.', '.', options('../unsafe'))
        end, 'run id must contain only letters, digits, dot, underscore, or dash')
        assert.equals(0, #callbacks)
    end)

    it('installs internal reset hooks around every Busted example', function()
        local hooks = {}
        local reset_reasons = {}
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

        host.install_ds_lifecycle(busted, function(reason)
            table.insert(reset_reasons, reason)
        end)
        hooks.before_each()
        hooks.after_each()

        assert.same({'before example', 'after example'}, reset_reasons)
    end)

    it('clears cached test dependencies without touching unrelated modules',
            function()
        local loaded = {
            ['busted.core']={},
            cliargs={},
            dkjson={},
            lfs={},
            luassert={},
            mediator={},
            ['pl.path']={},
            say={},
            system={},
            ['term.colors']={},
            ['gui.widgets']={},
            json={},
        }

        host.clear_dependency_modules(loaded)

        assert.same({}, loaded['gui.widgets'])
        assert.same({}, loaded.json)
        assert.is_nil(loaded['busted.core'])
        assert.is_nil(loaded.cliargs)
        assert.is_nil(loaded.dkjson)
        assert.is_nil(loaded.lfs)
        assert.is_nil(loaded.luassert)
        assert.is_nil(loaded.mediator)
        assert.is_nil(loaded['pl.path'])
        assert.is_nil(loaded.say)
        assert.is_nil(loaded.system)
        assert.is_nil(loaded['term.colors'])
    end)

    it('owns project module paths and newly loaded project modules', function()
        local separator = package.config:sub(1, 1)
        local project_root = 'consumer-project'
        local dependency_path = 'dependencies' .. separator .. '?.lua'
        local original_path = dependency_path .. ';dfhack' .. separator ..
            '?.lua'
        local existing = {}
        local external = {}
        local runtime_package = {
            path=original_path,
            loaded={existing=existing},
        }

        ---Finds only the fake consumer module in the supplied project paths.
        ---@param name string
        ---@param search_path string
        ---@return string|nil
        function runtime_package.searchpath(name, search_path)
            if name == 'support.fixture' and
                    search_path:find(project_root, 1, true) then
                return project_root .. separator .. 'support' .. separator ..
                    'fixture.lua'
            end
            if name == 'protected.fixture' and
                    search_path:find('dependencies', 1, true) then
                return 'dependencies' .. separator .. 'protected' ..
                    separator .. 'fixture.lua'
            end
            return nil
        end

        local restore = host.configure_project_modules(project_root,
            {dependency_path}, runtime_package)
        assert.equals(table.concat({
            dependency_path,
            project_root .. separator .. '?.lua',
            project_root .. separator .. '?' .. separator .. 'init.lua',
            'dfhack' .. separator .. '?.lua',
        }, ';'), runtime_package.path)

        runtime_package.loaded['support.fixture'] = {value='consumer'}
        runtime_package.loaded['protected.fixture'] = {value='dependency'}
        runtime_package.loaded.external = external
        runtime_package.loaded[1] = {value='non-string key'}
        restore()
        restore()

        assert.equals(original_path, runtime_package.path)
        assert.equals(existing, runtime_package.loaded.existing)
        assert.equals(external, runtime_package.loaded.external)
        assert.is_nil(runtime_package.loaded['support.fixture'])
        assert.same({value='dependency'},
            runtime_package.loaded['protected.fixture'])
        assert.same({value='non-string key'}, runtime_package.loaded[1])
    end)
end)
