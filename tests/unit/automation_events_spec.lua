-- Unit contracts for bounded structured automation event journals.

local events = require('dwarfspec.automation.events')
local EventType = require('dwarfspec.automation.event_types')

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
            status='success',
            duration_ms=5,
        },
        [EventType.PROBLEM_RECORDED]={
            kind='failure',
            name='suite test',
            message='expected true',
            trace='trace',
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
            terminal_state='passed',
            totals=counts,
            cleanup_required=true,
            cleanup_confirmed=true,
        },
        [EventType.SCHEDULER_BLOCKED]={
            reason='cleanup was not confirmed',
        },
    }
end

describe('automation structured events', function()
    it('publishes every initial event type with contiguous envelopes',
            function()
        local journal = events.new_journal(identity())
        local samples = payloads()
        local types = events.types()

        assert.equals(18, #types)
        for index, event_type in ipairs(types) do
            local identifier = EventType.id(event_type)
            local event = events.publish(journal, event_type,
                samples[event_type], 100 + index)
            assert.equals('dwarfspec.event.v1', event.schema)
            assert.equals('service-events-1', event.service_instance_id)
            assert.equals('project-events-1', event.project_id)
            assert.equals('run-events-1', event.run_id)
            assert.equals(7, event.generation)
            assert.equals(index, event.sequence)
            assert.equals(index, event.elapsed_ms)
            assert.equals(identifier, event.type)
        end
        assert.equals(#types, #events.validate_journal(journal).events)
    end)

    it('supports every terminal run state', function()
        for _, state in ipairs({'passed', 'failed', 'aborted', 'cancelled'}) do
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
        end, 'event type must be a DwarfSpec EventType')
        assert.has_error(function()
            events.validate_payload('unknown.event', {})
        end, 'unsupported automation event type: unknown.event')
        assert.has_error(function()
            events.publish(journal, EventType.TEST_FINISHED, {
                name='test',
                status='success',
            }, 100)
        end, 'event payload for test.finished is missing field: duration_ms')

        local event = events.publish(
            journal, EventType.RUN_ACTIVATED, {queue_wait_ms=0}, 100)
        event.run_id = 'foreign-run'
        assert.has_error(function()
            events.validate(event, identity())
        end, 'automation event identity mismatch: run_id')
    end)

    it('provides immutable event-type enum values', function()
        assert.equals('run.queued', EventType.id(EventType.RUN_QUEUED))
        assert.equals('RUN_QUEUED', EventType.name(EventType.RUN_QUEUED))
        assert.equals(EventType.RUN_QUEUED,
            EventType.from_id('run.queued'))
        assert.is_true(EventType.is(EventType.RUN_QUEUED))
        assert.is_false(EventType.is('run.queued'))
        assert.has_error(function()
            EventType.RUN_QUEUED = EventType.RUN_FINISHED
        end, 'DwarfSpec EventType is immutable: RUN_QUEUED')
        assert.has_error(function()
            EventType.RUN_QUEUED.id = 'mutated'
        end, 'DwarfSpec EventType is immutable: id')
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
