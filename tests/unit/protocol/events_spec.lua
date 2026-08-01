-- Unit contracts for bounded structured automation event journals.

local events = require('dwarfspec.protocol.events')
local EComparison =
    require('dwarfspec.protocol.diagnostics.base_screen_focus_comparisons')
local EventType = require('dwarfspec.protocol.enums.event_types')
local RunState = require('dwarfspec.protocol.enums.run_states')
local SchedulerFailureKind =
    require('dwarfspec.protocol.enums.scheduler_failure_kinds')
local TestStatus = require('dwarfspec.protocol.enums.test_statuses')

---Returns one deterministic journal identity.
---@return table
local function identity()
    return {
        service_instance_id='service-events-1',
        project_id='project-events-1',
        run_id='run-events-1',
        generation=7,
        admitted_at_ms=100,
    }
end

---Returns representative valid payloads for every initial event type.
---@return table
local function payloads()
    local counts = {successes=1, failures=0, errors=0, pending=0}
    return {
        [EventType.RUN_QUEUED]={
            selection={identities={'tests/example.ds.lua'}},
            queue_admitted_ms=100,
            owner_kind='external',
        },
        [EventType.RUN_ACTIVATED]={queue_wait_ms=10},
        [EventType.RUN_CANCELLED]={
            reason='caller cancelled',
            owner='external',
        },
        [EventType.RUN_STARTED]={repeat_count=1, options={shuffle=false}},
        [EventType.REPEAT_STARTED]={repeat_index=1, repeat_count=1},
        [EventType.REPEAT_FINISHED]={repeat_index=1, counts=counts},
        [EventType.TEST_STARTED]={
            name='suite test',
            source_identity='tests/example.ds.lua',
        },
        [EventType.TEST_FINISHED]={
            name='suite test',
            status=TestStatus.SUCCESS,
            duration_ms=5,
        },
        [EventType.PROBLEM_RECORDED]={
            kind='failure',
            name='suite test',
            message='expected true',
            trace='trace',
            source_identity='tests/example.ds.lua',
            line=12,
            column=4,
        },
        [EventType.COMMAND_STARTED]={
            name='click',
            subject_identity='screen/button',
            safe_arguments={button='left'},
        },
        [EventType.COMMAND_FINISHED]={
            name='click',
            status='success',
            duration_ms=2,
            snapshot_sequence=4,
        },
        [EventType.DIAGNOSTIC_RECORDED]={
            kind='component_tree',
            content={name='root', children={}},
        },
        [EventType.CLEANUP_STARTED]={
            reason='run finished',
            pending_action_count=2,
        },
        [EventType.CLEANUP_FAILED]={
            action_name='unmount',
            reason='callback failed',
            message='fixture cleanup failure',
            trace='trace',
        },
        [EventType.CLEANUP_FINISHED]={
            cleanup_confirmed=true,
            mount_cleanup_verified=true,
        },
        [EventType.RUN_ABORTED]={reason='external timeout'},
        [EventType.RUN_FINISHED]={
            terminal_state=RunState.PASSED,
            totals=counts,
            cleanup_required=true,
            cleanup_confirmed=true,
        },
        [EventType.SCHEDULER_BLOCKED]={
            kind=SchedulerFailureKind.EXECUTOR_QUARANTINED,
            reason='cleanup was not confirmed',
            blocking_run_id='run-blocking-1',
            blocking_generation=6,
        },
    }
end

---Returns one detached focus observation fixture.
---@param focus_available boolean
---@param screen_type string|nil
---@return table
local function focus_details(focus_available, screen_type)
    return {
        screen={
            status='present',
            type=screen_type or 'viewscreen_dwarfmodest',
        },
        focus=focus_available and {
            status='available',
            values={'dwarfmode/Default'},
        } or {
            status='unavailable',
            values={},
            error='focus capture failed',
        },
    }
end

---Returns one valid focus diagnostic fixture.
---@param kind string
---@param scope 'example'|'suite'
---@param incomplete boolean
---@return table
local function focus_diagnostic(kind, scope, incomplete)
    local changed = kind == 'base_screen_focus_changed'
    local content = {
        severity=changed and 'warning' or 'info',
        scope=scope,
        attribution=scope == 'suite' and 'file' or 'test',
        suite_name='tests/focus_spec.lua',
        source_identity='tests/focus_spec.lua',
        repeat_index=2,
        screen_comparison=changed and EComparison.CHANGED or
            EComparison.SAME,
        focus_comparison=incomplete and EComparison.UNAVAILABLE or
            EComparison.SAME,
        details_complete=not incomplete,
        before=focus_details(not incomplete, 'viewscreen_before'),
        after=focus_details(not incomplete,
            changed and 'viewscreen_after' or 'viewscreen_before'),
    }
    if scope == 'example' then
        content.example_name='focus suite changes focus'
    end
    return {kind=kind, content=content}
end

describe('automation structured events', function()
    it('publishes every initial event type with contiguous envelopes',
            function()
        local journal = events.new_journal(identity())
        local samples = payloads()
        local types = events.types()

        assert.equals(18, #types)
        for index, event_type in ipairs(types) do
            local event = events.publish(journal, event_type,
                samples[event_type], 100 + index)
            assert.equals('dwarfspec.event.v1', event.schema)
            assert.equals('service-events-1', event.service_instance_id)
            assert.equals('project-events-1', event.project_id)
            assert.equals('run-events-1', event.run_id)
            assert.equals(7, event.generation)
            assert.equals(index, event.sequence)
            assert.equals(index, event.elapsed_ms)
            assert.equals(event_type, event.type)
        end
        assert.equals(#types, #events.validate_journal(journal).events)
    end)

    it('supports every terminal run state', function()
        for _, state in ipairs({
                RunState.PASSED,
                RunState.FAILED,
                RunState.ABORTED,
                RunState.CANCELLED}) do
            local journal = events.new_journal(identity())
            local event = events.publish(journal, EventType.RUN_FINISHED, {
                terminal_state=state,
                totals={successes=0, failures=0, errors=0, pending=0},
                cleanup_required=state ~= 'cancelled',
                cleanup_confirmed=true,
            }, 101)
            assert.equals(state, event.payload.terminal_state)
        end
    end)

    it('returns deterministic detached cursor reads and empty retries',
            function()
        local journal = events.new_journal(identity())
        local source = payloads()[EventType.RUN_QUEUED]
        local published = events.publish(
            journal, EventType.RUN_QUEUED, source, 105)
        source.selection.identities[1] = 'mutated source'
        published.payload.selection.identities[1] = 'mutated result'

        local first = events.read(journal, 0)
        local retry = events.read(journal, 0)
        first.events[1].payload.selection.identities[1] = 'mutated read'
        local after = events.read(journal, 1)

        assert.same(retry, events.read(journal, 0))
        assert.equals('tests/example.ds.lua',
            retry.events[1].payload.selection.identities[1])
        assert.same({events={}, last_sequence=1}, after)
    end)

    it('rejects stale cursors and sequence discontinuity', function()
        local journal = events.new_journal(identity())
        events.publish(journal, EventType.RUN_ACTIVATED,
            {queue_wait_ms=1}, 101)

        assert.has_error(function()
            events.read(journal, 2)
        end, 'stale event cursor is ahead of journal: 2 > 1')

        journal.events[1].sequence = 2
        assert.has_error(function()
            events.read(journal, 0)
        end, 'automation event sequence discontinuity: expected 1, found 2')

        local sparse = events.new_journal(identity())
        sparse.events[1] = journal.events[1]
        sparse.events[3] = journal.events[1]
        assert.has_error(function()
            events.validate_journal(sparse)
        end, 'JSON-safe array automation event journal must be dense')
    end)

    it('rejects malformed event identities and payloads', function()
        local journal = events.new_journal(identity())
        assert.has_error(function()
            events.publish(journal, 'unknown.event', {}, 100)
        end, 'unsupported automation event type: unknown.event')
        assert.has_error(function()
            events.validate_payload('unknown.event', {})
        end, 'unsupported automation event type: unknown.event')
        assert.has_error(function()
            events.publish(journal, EventType.TEST_FINISHED, {
                name='test',
                status=TestStatus.SUCCESS,
            }, 100)
        end, 'event payload for test.finished is missing field: duration_ms')

        local event = events.publish(
            journal, EventType.RUN_ACTIVATED, {queue_wait_ms=0}, 100)
        event.run_id = 'foreign-run'
        assert.has_error(function()
            events.validate(event, identity())
        end, 'automation event identity mismatch: run_id')
    end)

    it('validates every optional problem location field combination',
            function()
        local base = {
            kind='failure',
            name='suite test',
            message='expected true',
        }
        for _, location in ipairs({
                {},
                {source_identity='tests/example.ds.lua'},
                {line=12},
                {source_identity='tests/example.ds.lua', line=12},
                {line=12, column=4},
                {
                    source_identity='tests/example.ds.lua',
                    line=12,
                    column=4,
                },
            }) do
            local payload = events.copy_json(base)
            for field, value in pairs(location) do payload[field] = value end
            assert.same(payload,
                events.validate_problem(payload, 'fixture problem'))
        end

        local invalid = {
            {source_identity=''},
            {source_identity=7},
            {line=0},
            {line=-1},
            {line=1.5},
            {line='12'},
            {column=4},
            {line=1, column=0},
            {line=1, column=-1},
            {line=1, column=1.5},
            {line=1, column='4'},
        }
        for _, location in ipairs(invalid) do
            local payload = events.copy_json(base)
            for field, value in pairs(location) do payload[field] = value end
            assert.has_error(function()
                events.validate_payload(
                    EventType.PROBLEM_RECORDED, payload)
            end)
        end
    end)

    it('validates example and suite focus change diagnostics', function()
        for _, fixture in ipairs({
                focus_diagnostic(
                    'base_screen_focus_changed', 'example', false),
                focus_diagnostic(
                    'base_screen_focus_changed', 'suite', false),
                focus_diagnostic(
                    'base_screen_focus_changed', 'example', true),
                focus_diagnostic(
                    'base_screen_focus_changed', 'suite', true),
            }) do
            local journal = events.new_journal(identity())
            local event = events.publish(journal,
                EventType.DIAGNOSTIC_RECORDED, fixture, 101)
            assert.equals('warning', event.payload.content.severity)
            assert.equals(fixture.content.scope,
                event.payload.content.scope)
            fixture.content.before.screen.type = 'mutated after publish'
            assert.equals('viewscreen_before',
                journal.events[1].payload.content.before.screen.type)
        end
    end)

    it('validates example and suite incomplete-verification diagnostics',
            function()
        for _, scope in ipairs({'example', 'suite'}) do
            local fixture = focus_diagnostic(
                'base_screen_focus_verification_incomplete', scope, true)
            local journal = events.new_journal(identity())
            local event = events.publish(journal,
                EventType.DIAGNOSTIC_RECORDED, fixture, 101)
            assert.equals('info', event.payload.content.severity)
            assert.is_false(event.payload.content.details_complete)
        end
    end)

    it('rejects malformed focus diagnostic contracts', function()
        local mutations = {
            function(value) value.content.severity = 'info' end,
            function(value) value.content.scope = 'nested' end,
            function(value) value.content.attribution = 'file' end,
            function(value) value.content.suite_name = '' end,
            function(value) value.content.example_name = nil end,
            function(value) value.content.repeat_index = 0 end,
            function(value)
                value.content.screen_comparison = 999
            end,
            function(value) value.content.details_complete = false end,
            function(value)
                value.content.before.screen.status = 'unknown'
            end,
            function(value)
                value.content.before.focus.values[1] = io.stdout
            end,
            function(value)
                value.content.before.screen.type =
                    'viewscreen_dwarfmodestst: 0x1234ABCD'
            end,
            function(value)
                value.content.before.private = {identity='forbidden'}
            end,
        }
        for _, mutate in ipairs(mutations) do
            local fixture = focus_diagnostic(
                'base_screen_focus_changed', 'example', false)
            mutate(fixture)
            assert.has_error(function()
                events.validate_payload(
                    EventType.DIAGNOSTIC_RECORDED, fixture)
            end)
        end

        local incomplete = focus_diagnostic(
            'base_screen_focus_verification_incomplete', 'suite', true)
        incomplete.content.focus_comparison = EComparison.CHANGED
        assert.has_error(function()
            events.validate_payload(
                EventType.DIAGNOSTIC_RECORDED, incomplete)
        end)
        incomplete = focus_diagnostic(
            'base_screen_focus_verification_incomplete', 'suite', true)
        incomplete.content.severity = 'warning'
        assert.has_error(function()
            events.validate_payload(
                EventType.DIAGNOSTIC_RECORDED, incomplete)
        end)
    end)

    it('preserves existing command and operator diagnostic kinds',
            function()
        for _, fixture in ipairs({
                {kind='command_failure', content={
                    name='click', message='target disappeared'}},
                {kind='component_tree', content={
                    name='root', children={}}},
                {kind='operator_cancel', content={
                    reason='requested', authority='operator'}},
                {kind='operator_abort', content={
                    reason='requested', authority='operator'}},
                {kind='operator_discard', content={
                    reason='requested', authority='operator'}},
            }) do
            assert.has_no.errors(function()
                events.validate_payload(
                    EventType.DIAGNOSTIC_RECORDED, fixture)
            end)
        end
    end)

    it('provides immutable event-type enum values', function()
        assert.equals('run.queued', EventType.RUN_QUEUED)
        local values = {}
        for name, value in pairs(EventType) do values[name] = value end
        assert.equals('run.queued', values.RUN_QUEUED)
        assert.equals('run.finished', values.RUN_FINISHED)
        assert.has_error(function()
            EventType.RUN_QUEUED = EventType.RUN_FINISHED
        end, 'Enums are immutable.')
    end)

    it('bounds JSON values and excludes capabilities and live objects',
            function()
        local cyclic = {}
        cyclic.self = cyclic
        assert.has_error(function()
            events.copy_json(cyclic)
        end, 'JSON-safe value contains a cycle at value.self')
        assert.has_error(function()
            events.copy_json({callback=function() end})
        end, 'JSON-safe value value.callback has unsupported type function')
        assert.has_error(function()
            events.copy_json({thread=coroutine.create(function() end)})
        end, 'JSON-safe value value.thread has unsupported type thread')
        assert.has_error(function()
            events.copy_json({owner_capability='secret'})
        end, 'owner capability is forbidden at value')
        assert.has_error(function()
            events.copy_json(setmetatable({name='screen'}, {}))
        end, 'JSON-safe table must not have a behavioral metatable at value')
        assert.has_error(function()
            events.copy_json(setmetatable({}, {__metatable='protected'}))
        end, 'JSON-safe table has a protected metatable at value')
        assert.has_error(function()
            events.copy_json({nested={value=true}}, nil, {max_depth=1})
        end, 'JSON-safe value exceeds maximum depth at value.nested.value')
        assert.has_error(function()
            events.copy_json({one=true, two=true}, nil, {max_nodes=2})
        end)
        assert.has_error(function()
            events.copy_json({text='abcd'}, nil, {max_string_bytes=3})
        end, 'JSON-safe string exceeds maximum byte length at value.text')
    end)
end)
