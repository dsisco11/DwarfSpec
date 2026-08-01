-- Unit contracts for live automation ownership and generation guards.

local host_path = 'src/dwarfspec/automation/host.lua'
local EComparison =
    require('dwarfspec.protocol.diagnostics.base_screen_focus_comparisons')
local FileSuiteIdentity =
    require('dwarfspec.automation.file_suite_identity')
local EventType = require('dwarfspec.protocol.enums.event_types')
local RunState = require('dwarfspec.protocol.enums.run_states')
local SchedulerFailureKind =
    require('dwarfspec.protocol.enums.scheduler_failure_kinds')

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

    ---Creates one isolated real Busted 2.3.0 runtime.
    ---@return table
    local function new_busted()
        local busted = require('busted.core')()
        local init_path = assert(package.searchpath('busted', package.path))
        assert(loadfile(init_path))()(busted)
        busted.randomize = false
        busted.sort = false
        busted.randomseed = 1
        return busted
    end

    ---Registers one compiled in-memory spec file.
    ---@param busted table
    ---@param file_name string
    ---@param source string
    local function register_file(busted, file_name, source)
        local body = assert(load(source, '@' .. file_name))
        local callable = setmetatable({
            getTrace=function(_, trace) return trace end,
            rewriteMessage=function(_, message) return message end,
        }, {__call=body})
        busted.executors.file(file_name, callable)
    end

    ---Executes one isolated Busted runtime.
    ---@param busted table
    local function execute_busted(busted)
        assert(loadfile(
            '.luarocks/share/lua/5.4/busted/execute.lua'))()(busted)(1, {
                seed=1,
                shuffle=false,
                sort=false,
            })
    end

    ---Creates a deterministic guard that reports every comparison as changed.
    ---@param journal table[]
    ---@return table
    local function changing_guard(journal)
        local capture_count = 0
        return {
            capture=function()
                capture_count = capture_count + 1
                local previous = journal[#journal]
                local label
                if capture_count == 1 then
                    label = 'S0'
                elseif type(previous) == 'string' and
                        previous:match('after suite$') then
                    label = 'S2'
                else
                    label = capture_count % 2 == 0 and 'T0' or 'T1'
                end
                table.insert(journal, label)
                return {capture=capture_count}
            end,
            compare=function(_, before, after)
                assert.is_true(before.capture < after.capture)
                if after.capture - before.capture ~= 1 then return nil end
                return {
                    kind='base_screen_focus_changed',
                    content={
                        severity='warning',
                        screen_comparison=EComparison.CHANGED,
                        focus_comparison=EComparison.SAME,
                        details_complete=true,
                        before={
                            screen={status='present', type='viewscreen_a'},
                            focus={status='available', values={'a'}},
                        },
                        after={
                            screen={status='present', type='viewscreen_b'},
                            focus={status='available', values={'a'}},
                        },
                    },
                }
            end,
        }
    end

    ---Installs production example lifecycle callbacks on a real Busted runtime.
    ---@param busted table
    ---@param journal table[]
    ---@param reset function
    ---@param guard table
    ---@return table, table
    local function install_focus_lifecycle(
            busted, journal, reset, guard)
        local published = {}
        local run = {
            event_publisher={
                publish=function(event_type, payload)
                    table.insert(published, {
                        type=event_type,
                        payload=payload,
                    })
                    if event_type == EventType.DIAGNOSTIC_RECORDED then
                        table.insert(journal, 'diagnostic')
                    end
                end,
            },
        }
        local adapter = assert(loadfile(
            'src/dwarfspec/automation/busted_lifecycle_adapter.lua'))()
        local lifecycle = host.new_focus_lifecycle(
            run, reset, guard)
        adapter.install(busted, {
            project_root='.',
            on_suite_entry=lifecycle.suite_entry,
            on_suite_exit=lifecycle.suite_exit,
            on_test_start=lifecycle.test_start,
        })
        host.install_ds_example_entry(adapter, busted, lifecycle)
        host.install_ds_example_exit(adapter, busted, lifecycle)
        busted.subscribe({'test', 'end'}, function(_, _, status)
            table.insert(journal, status:upper())
            return nil, true
        end)
        busted.subscribe({'error'}, function(element)
            table.insert(journal, 'ERROR ' .. element.descriptor)
            return nil, true
        end)
        return run, published
    end

    it('initializes and retains the version 2 service registry shape',
            function()
        assert.is_nil(dfhack.dwarfspec)

        local run = host.start('.', '.', options('registry-contract'))
        local registry = dfhack.dwarfspec

        assert.equals(2, registry.protocol_version)
        assert.equals('dwarfspec.service.v2', registry.schema)
        assert.equals(1, registry.generation)
        assert.equals(run.run_id, registry.active_run_id)
        assert.equals(run, registry.runs[run.run_id])
        assert.equals(run.project_id,
            registry.projects[run.project_id].project_id)

        local aborted = host.abort(run.run_id, run.owner_capability)
        assert.is_nil(registry.active_run_id)
        assert.equals(aborted.run_id,
            registry.latest_terminal_results[aborted.project_id])
        assert.is_false(aborted.terminal_observed)
        assert.equals(aborted.run_id,
            registry.projects[aborted.project_id].outstanding_run_id)

        assert.equals(aborted, host.observe(run.run_id))
        assert.is_false(aborted.terminal_observed)
        assert.is_false(aborted.acknowledged == true)
        host.acknowledge(aborted.run_id, aborted.generation,
            aborted.owner_capability)
        assert.is_true(host.observe(run.run_id).acknowledged)
        assert.is_nil(registry.projects[aborted.project_id].
            outstanding_run_id)
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
                tracked_screen_count=cleaned and 0 or 1,
                owned_screen_count=cleaned and 0 or 1,
                subject_count=cleaned and 0 or 1,
                pointer_active=not cleaned,
            }
        end
        local focus_lifecycle_cleared = false
        run.focus_lifecycle = {
            clear=function()
                focus_lifecycle_cleared = true
            end,
        }
        local aborted = host.abort('owner', run.owner_capability)
        assert.equals('aborted', aborted.state)
        assert.is_nil(active_callbacks[1])
        assert.is_nil(active_callbacks[2])
        assert.is_true(cleaned)
        assert.is_true(focus_lifecycle_cleared)
        assert.is_nil(aborted.focus_lifecycle)
        assert.is_true(aborted.cleanup_confirmed)
        assert.is_true(aborted.mount_cleanup_state.verified)
        assert.equals(0, aborted.mount_cleanup_state.active_screen_count)
        local event_types = {}
        for _, event in ipairs(aborted.event_journal.events) do
            table.insert(event_types, event.type)
        end
        assert.same({
            EventType.RUN_QUEUED,
            EventType.RUN_ACTIVATED,
            EventType.RUN_ABORTED,
            EventType.CLEANUP_STARTED,
            EventType.CLEANUP_FINISHED,
            EventType.RUN_FINISHED,
        }, event_types)
        callbacks[1]()
        callbacks[2]()
        assert.equals('aborted', aborted.state)
        assert.equals(aborted, host.find('owner'))
    end)

    it('retains an unobserved result until its owner acknowledges it', function()
        local retained = host.start('.', '.', options('retained'))
        local aborted = host.abort(retained.run_id,
            retained.owner_capability)
        assert.has_error(function()
            host.start('.', '.', options('replacement'))
        end, 'automation run retained has an unobserved aborted result')

        host.acknowledge(aborted.run_id, aborted.generation,
            aborted.owner_capability)
        local replacement = host.start('.', '.', options('replacement'))
        assert.equals('starting', replacement.state)
        host.abort(replacement.run_id, replacement.owner_capability)
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
                tracked_screen_count=cleaned and 0 or 1,
                owned_screen_count=cleaned and 0 or 1,
                subject_count=cleaned and 0 or 1,
                pointer_active=not cleaned,
            }
        end
        local focus_lifecycle_cleared = false
        run.focus_lifecycle = {
            clear=function()
                focus_lifecycle_cleared = true
            end,
        }

        tick = 100
        callbacks[2]()

        assert.equals('aborted', run.state)
        assert.is_true(cleaned)
        assert.is_true(focus_lifecycle_cleared)
        assert.is_nil(run.focus_lifecycle)
        assert.is_true(run.cleanup_confirmed)
        assert.is_true(run.mount_cleanup_state.verified)
        assert.matches('execution lease expired', run.output_lines[1],
            1, true)
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
                owned_screen_count=1,
                subject_count=1,
                pointer_active=true,
            }
        end

        local aborted = host.abort(run.run_id, run.owner_capability)

        assert.is_false(aborted.cleanup_confirmed)
        assert.equals(1, aborted.totals.errors)
        assert.is_false(aborted.mount_cleanup_state.verified)
        assert.equals(1, aborted.mount_cleanup_state.active_screen_count)
        assert.matches('mount lifecycle verification failed',
            aborted.failure_details[1].message, 1, true)
        assert.has_error(function()
            host.recover_executor(aborted.run_id, aborted.generation,
                'unsafe fixture recovery')
        end, 'quarantined mount state is not clean')
    end)

    it('refuses cleanup confirmation for retained ownership evidence',
            function()
        local run = host.start('.', '.', options('retained-ownership'))
        run.mount_cleanup_probe = function()
            return {
                current_mount_id=nil,
                active_screen_count=0,
                tracked_screen_count=1,
                owned_screen_count=1,
                borrowed_native_screen_count=1,
                native_attachment_count=1,
                native_screen_dismissal_count=1,
                subject_count=0,
                pointer_active=false,
            }
        end

        local aborted = host.abort(run.run_id, run.owner_capability)

        assert.is_false(aborted.cleanup_confirmed)
        assert.is_false(aborted.mount_cleanup_state.verified)
        assert.has_error(function()
            host.recover_executor(aborted.run_id, aborted.generation,
                'unsafe retained ownership recovery')
        end, 'quarantined mount state is not clean')
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

        local aborted = host.abort(run.run_id, run.owner_capability)

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
        assert.is_true(host.scheduler_snapshot().quarantine.active)
        local recovered = host.recover_executor(aborted.run_id,
            aborted.generation, 'cleanup history reviewed')
        assert.is_true(recovered.recovered)
        assert.is_false(host.scheduler_snapshot().quarantine.active)
    end)

    it('rejects quarantine before registering or admitting another run',
            function()
        local run = host.start('.', '.', options('blocking-cleanup'))
        run.cleanup_module.push(run.cleanup_registry, 'broken cleanup',
            function() error('cleanup exploded') end)
        host.abort(run.run_id, run.owner_capability)
        local registry = dfhack.dwarfspec
        local generation_before = registry.generation
        local projects_before = registry.projects

        local accepted, rejection = pcall(host.start, '.', 'other-project',
            options('must-not-be-admitted'))

        assert.is_false(accepted)
        assert.is_table(rejection)
        assert.equals(SchedulerFailureKind.EXECUTOR_QUARANTINED,
            rejection.kind)
        assert.equals(run.run_id, rejection.blocking_run_id)
        assert.equals(run.generation, rejection.blocking_generation)
        assert.equals(generation_before, registry.generation)
        assert.equals(projects_before, registry.projects)
        for _, project in pairs(registry.projects) do
            assert.not_equals('other-project',
                project.normalized_project_root)
        end
        assert.is_nil(registry.runs['must-not-be-admitted'])
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

    it('splits internal entry and exit hooks around every Busted example',
            function()
        local hooks = {}
        local lifecycle = {
            example_entry=function() end,
            example_exit=function() end,
        }
        local busted = {
            version='2.3.0',
            api={
                before_each=function(callback)
                    hooks.before_each = callback
                end,
                after_each=function(callback)
                    hooks.after_each = callback
                end,
            },
        }
        local lifecycle_adapter = assert(loadfile(
            'src/dwarfspec/automation/busted_lifecycle_adapter.lua'))()

        host.install_ds_example_entry(
            lifecycle_adapter, busted, lifecycle)
        host.install_ds_example_exit(
            lifecycle_adapter, busted, lifecycle)

        assert.equals(lifecycle.example_entry, hooks.before_each)
        assert.equals(lifecycle.example_exit, hooks.after_each)
    end)

    it('orders cleanup observations around the complete ordinary example',
            function()
        local busted = new_busted()
        local journal = {}
        busted.export('journal', journal)
        local reset = function(reason)
            table.insert(journal, 'reset ' .. reason)
            table.insert(journal, 'settlement ' .. reason)
        end
        install_focus_lifecycle(
            busted, journal, reset, changing_guard(journal))
        register_file(busted, 'tests/ordered_spec.lua', [[
            setup(function() table.insert(journal, 'suite setup') end)
            before_each(function()
                table.insert(journal, 'project before_each')
            end)
            after_each(function()
                table.insert(journal, 'project after_each')
            end)
            it('ordinary example', function()
                finally(function() table.insert(journal, 'finally') end)
                table.insert(journal, 'example')
            end)
        ]])

        execute_busted(busted)

        assert.same({
            'S0',
            'suite setup',
            'reset before example',
            'settlement before example',
            'T0',
            'project before_each',
            'example',
            'finally',
            'SUCCESS',
            'project after_each',
            'reset after example',
            'settlement after example',
            'T1',
            'diagnostic',
            'reset after suite',
            'settlement after suite',
            'S2',
        }, journal)
    end)

    it('captures T1 after nested and top-level project after_each hooks',
            function()
        local busted = new_busted()
        local journal = {}
        busted.export('journal', journal)
        install_focus_lifecycle(busted, journal, function(reason)
            table.insert(journal, 'reset ' .. reason)
        end, changing_guard(journal))
        register_file(busted, 'tests/nested_after_spec.lua', [[
            after_each(function() table.insert(journal, 'file after') end)
            describe('nested', function()
                after_each(function()
                    table.insert(journal, 'nested after')
                end)
                it('runs', function() end)
            end)
        ]])

        execute_busted(busted)

        local nested_after
        local file_after
        local final_capture
        for index, event in ipairs(journal) do
            if event == 'nested after' then nested_after = index end
            if event == 'file after' then file_after = index end
            if event == 'T1' then final_capture = index end
        end
        assert.is_true(nested_after < file_after)
        assert.is_true(file_after < final_capture)
    end)

    it('compares after example failure and continuing after_each failures',
            function()
        local busted = new_busted()
        local journal = {}
        busted.export('journal', journal)
        local _, published = install_focus_lifecycle(
            busted, journal, function(reason)
                table.insert(journal, 'reset ' .. reason)
            end, changing_guard(journal))
        register_file(busted, 'tests/failure_spec.lua', [[
            after_each(function()
                table.insert(journal, 'project after failure')
                error('after_each failure')
            end)
            it('fails', function() assert.is_true(false) end)
        ]])

        execute_busted(busted)

        assert.equals(1, #published)
        assert.equals(EventType.DIAGNOSTIC_RECORDED, published[1].type)
        local result_index
        local hook_index
        local capture_index
        for index, event in ipairs(journal) do
            if event == 'FAILURE' then result_index = index end
            if event == 'project after failure' then hook_index = index end
            if event == 'T1' then capture_index = index end
        end
        assert.is_true(result_index < hook_index)
        assert.is_true(hook_index < capture_index)
    end)

    it('attributes before_each failure without reusing an example name',
            function()
        local busted = new_busted()
        local journal = {}
        busted.export('journal', journal)
        local _, published = install_focus_lifecycle(
            busted, journal, function(reason)
                table.insert(journal, 'reset ' .. reason)
            end, changing_guard(journal))
        register_file(busted, 'tests/before_failure_spec.lua', [[
            local count = 0
            before_each(function()
                count = count + 1
                if count == 2 then error('before_each failure') end
            end)
            it('first name', function() end)
            it('second name', function() end)
        ]])

        execute_busted(busted)

        assert.equals(2, #published)
        local first = published[1].payload.content
        local second = published[2].payload.content
        assert.equals('example', first.scope)
        assert.equals('test', first.attribution)
        assert.equals('tests/before_failure_spec.lua', first.suite_name)
        assert.equals('tests/before_failure_spec.lua',
            first.source_identity)
        assert.equals(1, first.repeat_index)
        assert.matches('first name$', first.example_name)
        assert.equals('example', second.scope)
        assert.equals('before_each', second.attribution)
        assert.equals('tests/before_failure_spec.lua', second.suite_name)
        assert.equals(1, second.repeat_index)
        assert.is_nil(second.example_name)
        assert.is_nil(second.source_identity)
        local problem_index
        local diagnostic_index
        local diagnostics_seen = 0
        for index, event in ipairs(journal) do
            if event == 'ERROR before_each' then problem_index = index end
            if event == 'diagnostic' then
                diagnostics_seen = diagnostics_seen + 1
                if diagnostics_seen == 2 then diagnostic_index = index end
            end
        end
        assert.is_true(problem_index < diagnostic_index)
    end)

    it('cleans every mount category before T1 capture', function()
        local mount_state = {
            widget=1,
            overlay=1,
            screen=1,
            native_attachment=1,
        }
        local capture_count = 0
        local guard = {
            capture=function()
                capture_count = capture_count + 1
                if capture_count == 3 then
                    assert.same({
                        widget=0,
                        overlay=0,
                        screen=0,
                        native_attachment=0,
                    }, mount_state)
                end
                return {capture=capture_count}
            end,
            compare=function()
                return nil
            end,
        }
        local run = {
            event_publisher={publish=function() end},
        }
        local lifecycle = host.new_focus_lifecycle(
            run, function(reason)
                if reason == 'after example' then
                    for category in pairs(mount_state) do
                        mount_state[category] = 0
                    end
                end
            end, guard)
        lifecycle.suite_entry(FileSuiteIdentity.new({
            suite_id='suite#1',
            suite_name='tests/mounts_spec.lua',
            source_identity='tests/mounts_spec.lua',
            repeat_index=1,
            repeat_count=1,
        }))

        lifecycle.example_entry()
        lifecycle.test_start({example_name='mount categories'})
        lifecycle.example_exit()

        assert.equals(3, capture_count)
    end)

    it('keeps reset failure authoritative and skips final comparison',
            function()
        local capture_count = 0
        local compare_count = 0
        local reset_failed = false
        local lifecycle = host.new_focus_lifecycle({
            event_publisher={publish=function() end},
        }, function(reason)
            if reason == 'after example' and not reset_failed then
                reset_failed = true
                error('authoritative reset failure')
            end
        end, {
            capture=function()
                capture_count = capture_count + 1
                return {}
            end,
            compare=function()
                compare_count = compare_count + 1
            end,
        })
        lifecycle.suite_entry(FileSuiteIdentity.new({
            suite_id='suite#1',
            suite_name='tests/reset_spec.lua',
            source_identity='tests/reset_spec.lua',
            repeat_index=1,
            repeat_count=1,
        }))
        lifecycle.example_entry()

        assert.has_error(
            lifecycle.example_exit, 'authoritative reset failure')
        assert.equals(2, capture_count)
        assert.equals(0, compare_count)
        lifecycle.example_exit()
        assert.equals(0, compare_count)
    end)

    it('does not capture T0 after pre-example reset failure', function()
        local capture_count = 0
        local compare_count = 0
        local reset_failed = false
        local lifecycle = host.new_focus_lifecycle({
            event_publisher={publish=function() end},
        }, function(reason)
            if reason == 'before example' and not reset_failed then
                reset_failed = true
                error('pre-example settlement failure')
            end
        end, {
            capture=function()
                capture_count = capture_count + 1
                return {}
            end,
            compare=function()
                compare_count = compare_count + 1
            end,
        })
        lifecycle.suite_entry(FileSuiteIdentity.new({
            suite_id='suite#1',
            suite_name='tests/reset_spec.lua',
            source_identity='tests/reset_spec.lua',
            repeat_index=1,
            repeat_count=1,
        }))

        assert.has_error(
            lifecycle.example_entry, 'pre-example settlement failure')
        lifecycle.example_exit()

        assert.equals(1, capture_count)
        assert.equals(0, compare_count)
    end)

    it('observes only suite boundaries for pending examples', function()
        local busted = new_busted()
        local journal = {}
        local capture_count = 0
        install_focus_lifecycle(busted, journal, function() end, {
            capture=function()
                capture_count = capture_count + 1
                return {}
            end,
            compare=function()
                return nil
            end,
        })
        register_file(busted, 'tests/pending_lifecycle_spec.lua', [[
            pending('not executed')
        ]])

        execute_busted(busted)

        assert.equals(2, capture_count)
        assert.same({'PENDING'}, journal)
    end)

    it('publishes warnings without changing run outcomes', function()
        local published = {}
        local run = {
            counts={successes=1, failures=0, errors=0, pending=0},
            totals={successes=1, failures=0, errors=0, pending=0},
            output_lines={},
            failure_details={},
            state=RunState.PASSED,
            exit_status=0,
            cleanup_confirmed=true,
            mount_cleanup_verified=true,
            event_publisher={
                publish=function(event_type, payload)
                    table.insert(published, {
                        type=event_type,
                        payload=payload,
                    })
                end,
            },
        }
        local outcome = {
            counts=run.counts,
            totals=run.totals,
            state=run.state,
            exit_status=run.exit_status,
            cleanup_confirmed=run.cleanup_confirmed,
            mount_cleanup_verified=run.mount_cleanup_verified,
        }
        local lifecycle = host.new_focus_lifecycle(
            run, function() end, changing_guard({}))
        lifecycle.suite_entry(FileSuiteIdentity.new({
            suite_id='suite#1',
            suite_name='tests/nonfatal_spec.lua',
            source_identity='tests/nonfatal_spec.lua',
            repeat_index=1,
            repeat_count=1,
        }))
        lifecycle.example_entry()
        lifecycle.test_start({example_name='nonfatal warning'})
        lifecycle.example_exit()

        assert.equals(1, #published)
        assert.equals(EventType.DIAGNOSTIC_RECORDED, published[1].type)
        assert.same({
            'WARNING base-screen focus changed after example nonfatal ' ..
                'warning in tests/nonfatal_spec.lua (repeat=1 ' ..
                'attribution=test screen=changed focus=same complete=true)',
        }, run.output_lines)
        assert.same({}, run.failure_details)
        assert.equals(outcome.counts, run.counts)
        assert.equals(outcome.totals, run.totals)
        assert.equals(outcome.state, run.state)
        assert.equals(outcome.exit_status, run.exit_status)
        assert.equals(outcome.cleanup_confirmed, run.cleanup_confirmed)
        assert.equals(outcome.mount_cleanup_verified,
            run.mount_cleanup_verified)
    end)

    it('publishes incomplete verification without a retained warning',
            function()
        local published = {}
        local run = {
            output_lines={},
            failure_details={},
            event_publisher={
                publish=function(event_type, payload)
                    table.insert(published, {
                        type=event_type,
                        payload=payload,
                    })
                end,
            },
        }
        local lifecycle = host.new_focus_lifecycle(
            run, function() end, {
                capture=function() return {} end,
                compare=function()
                    return {
                        kind='base_screen_focus_verification_incomplete',
                        content={
                            severity='info',
                            screen_comparison=EComparison.SAME,
                            focus_comparison=EComparison.UNAVAILABLE,
                            details_complete=false,
                            before={
                                screen={
                                    status='present',
                                    type='viewscreen_dwarfmodest',
                                },
                                focus={
                                    status='unavailable',
                                    values={},
                                    error='focus capture failed',
                                },
                            },
                            after={
                                screen={
                                    status='present',
                                    type='viewscreen_dwarfmodest',
                                },
                                focus={
                                    status='unavailable',
                                    values={},
                                    error='focus capture failed',
                                },
                            },
                        },
                    }
                end,
            })
        lifecycle.suite_entry(FileSuiteIdentity.new({
            suite_id='suite#1',
            suite_name='tests/incomplete_spec.lua',
            source_identity='tests/incomplete_spec.lua',
            repeat_index=1,
            repeat_count=1,
        }))
        lifecycle.example_entry()
        lifecycle.test_start({example_name='incomplete observation'})
        lifecycle.example_exit()

        assert.equals(1, #published)
        assert.equals('base_screen_focus_verification_incomplete',
            published[1].payload.kind)
        assert.same({}, run.output_lines)
        assert.same({}, run.failure_details)
    end)

    it('publishes exactly one event and retained line for a suite warning',
            function()
        local published = {}
        local run = {
            output_lines={},
            failure_details={},
            event_publisher={
                publish=function(event_type, payload)
                    table.insert(published, {
                        type=event_type,
                        payload=payload,
                    })
                end,
            },
        }
        local lifecycle = host.new_focus_lifecycle(
            run, function() end, changing_guard({}))
        local suite = FileSuiteIdentity.new({
            suite_id='suite#1',
            suite_name='tests/suite_warning_spec.lua',
            source_identity='tests/suite_warning_spec.lua',
            repeat_index=1,
            repeat_count=1,
        })
        local state = lifecycle.suite_entry(suite)
        lifecycle.suite_exit(suite, state)

        assert.equals(1, #published)
        assert.equals(EventType.DIAGNOSTIC_RECORDED, published[1].type)
        assert.equals('suite', published[1].payload.content.scope)
        assert.same({
            'WARNING base-screen focus changed after suite ' ..
                'tests/suite_warning_spec.lua (repeat=1 attribution=file ' ..
                'screen=changed focus=same complete=true)',
        }, run.output_lines)
        assert.same({}, run.failure_details)
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

        local restore, audit = host.configure_project_modules(project_root,
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
        assert.is_true(audit.restored)
        assert.is_true(audit.path_restored)
        assert.same({'support.fixture'}, audit.evicted_modules)
    end)
end)
