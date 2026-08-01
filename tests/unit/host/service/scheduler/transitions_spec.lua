-- Direct contracts for atomic scheduler state transitions.

local admission = require('dwarfspec.host.service.scheduler.admission')
local transitions = require('dwarfspec.host.service.scheduler.transitions')
local queue = require('dwarfspec.host.service.scheduler.queue')
local EventType = require('dwarfspec.protocol.enums.event_types')
local RunState = require('dwarfspec.protocol.enums.run_states')
local support = assert(loadfile(
    'tests/unit/host/service/scheduler/support.lua'))()

describe('scheduler transitions', function()
    it('atomically cancels a queued record and appends terminal events', function()
        local dependencies, controls = support.environment()
        local project = support.project(dependencies, 'transitions')
        local admitted = admission.submit(controls.registry,
            project.project_id, support.submission('transitions'), dependencies)
        transitions.cancel_queued(controls.registry, admitted.run,
            'direct cancellation', 'external', 200)
        assert.equals(RunState.CANCELLED, admitted.run.state)
        assert.is_true(admitted.run.terminal)
        assert.same({}, controls.registry.queue)
        assert.equals(3, #admitted.run.event_journal.events)
    end)

    it('guards generations across running and cleanup transitions', function()
        local dependencies, controls = support.environment()
        local project = support.project(dependencies, 'lifecycle')
        local admitted = admission.submit(controls.registry,
            project.project_id, support.submission('lifecycle'), dependencies)
        queue.activate_next(controls.registry, dependencies)
        assert.has_error(function() transitions.start_active(controls.registry,
            admitted.identity.run_id, admitted.identity.generation + 1,
            {repeat_count=1, options={}}, dependencies) end)
        transitions.start_active(controls.registry, admitted.identity.run_id,
            admitted.identity.generation, {repeat_count=1, options={}},
            dependencies)
        transitions.begin_cleanup(controls.registry, admitted.identity.run_id,
            admitted.identity.generation, 'complete', 0, dependencies)
        assert.equals(RunState.CLEANING, admitted.run.state)
        assert.same({EventType.RUN_QUEUED, EventType.RUN_ACTIVATED,
            EventType.RUN_STARTED, EventType.CLEANUP_STARTED},
            (function()
                local result = {}
                for _, event in ipairs(admitted.run.event_journal.events) do
                    table.insert(result, event.type)
                end
                return result
            end)())
    end)

    it('releases clean executors and quarantines unconfirmed cleanup', function()
        local dependencies, controls = support.environment()
        local first_project = support.project(dependencies, 'clean')
        local first = admission.submit(controls.registry,
            first_project.project_id, support.submission('clean'), dependencies)
        queue.activate_next(controls.registry, dependencies)
        transitions.finish_active(controls.registry, first.identity.run_id,
            first.identity.generation, RunState.PASSED, true, nil, dependencies)
        assert.is_nil(controls.registry.active_run_id)
        assert.is_false(controls.registry.quarantine.active)

        local second_project = support.project(dependencies, 'unclean', {
            project_root='tests/framework/service_project_alpha',
        })
        local second = admission.submit(controls.registry,
            second_project.project_id, support.submission('unclean'), dependencies)
        queue.activate_next(controls.registry, dependencies)
        transitions.finish_active(controls.registry, second.identity.run_id,
            second.identity.generation, RunState.FAILED, false,
            'cleanup failed', dependencies)
        assert.is_true(controls.registry.quarantine.active)
        assert.equals(second.identity.run_id,
            controls.registry.quarantine.run_id)
    end)

    it('owns every lease timer state mutation', function()
        local run = {lease_timer_id=7, lease_timer_generation=2}
        assert.equals(7, transitions.detach_lease_timer(run))
        assert.equals(3, run.lease_timer_generation)
        transitions.attach_lease_timer(run, 8)
        transitions.clear_fired_lease_timer(run)
        transitions.record_lease_timer_error(run, 'timer failure')
        assert.is_nil(run.lease_timer_id)
        assert.equals('timer failure', run.lease_timer_error)
    end)
end)
