-- Direct contracts for scheduler FIFO policy.

local admission = require('dwarfspec.host.service.scheduler.admission')
local queue = require('dwarfspec.host.service.scheduler.queue')
local RunState = require('dwarfspec.protocol.enums.run_states')
local support = assert(loadfile(
    'tests/unit/host/service/scheduler/support.lua'))()

describe('scheduler queue policy', function()
    it('activates the FIFO head and transfers executor ownership', function()
        local dependencies, controls = support.environment()
        local project = support.project(dependencies, 'queue')
        local admitted = admission.submit(controls.registry,
            project.project_id, support.submission('queue'), dependencies)
        local outcome = queue.activate_next(controls.registry, dependencies)
        assert.is_true(outcome.activated)
        assert.equals(RunState.STARTING, admitted.run.state)
        assert.equals(admitted.identity.run_id, controls.registry.active_run_id)
        assert.same({}, controls.registry.queue)
    end)

    it('preserves FIFO order and blocks activation while quarantined', function()
        local dependencies, controls = support.environment()
        local first_project = support.project(dependencies, 'fifo-one')
        local second_project = support.project(dependencies, 'fifo-two', {
            project_root='tests/framework/service_project_alpha',
        })
        local first = admission.submit(controls.registry,
            first_project.project_id, support.submission('fifo-one'), dependencies)
        admission.submit(controls.registry, second_project.project_id,
            support.submission('fifo-two'), dependencies)
        controls.registry.quarantine = {active=true, reason='blocked'}
        assert.is_false(queue.activate_next(controls.registry,
            dependencies).activated)
        controls.registry.quarantine = {active=false}
        assert.equals(first.identity.run_id,
            queue.activate_next(controls.registry, dependencies).identity.run_id)
    end)

    it('rejects invalid activation and supports owner cancellation', function()
        local dependencies, controls = support.environment()
        local project = support.project(dependencies, 'reject')
        local admitted = admission.submit(controls.registry,
            project.project_id, support.submission('reject'), dependencies)
        controls.activation_rejection = 'project became incompatible'
        local rejected = queue.activate_next(controls.registry, dependencies)
        assert.is_false(rejected.activated)
        assert.equals(RunState.FAILED, admitted.run.state)

        local other_project = support.project(dependencies, 'cancel', {
            project_root='tests/framework/service_project_alpha',
        })
        local other = admission.submit(controls.registry,
            other_project.project_id, support.submission('cancel'), dependencies)
        local cancelled = queue.cancel(controls.registry,
            support.owner_request(other, {reason='no longer needed'}), dependencies)
        assert.is_true(cancelled.cancelled)
        assert.equals(RunState.CANCELLED, other.run.state)
    end)

    it('expires due queue leases and preserves unexpired runs', function()
        local dependencies, controls = support.environment()
        local first_project = support.project(dependencies, 'expiry-one')
        local second_project = support.project(dependencies, 'expiry-two', {
            project_root='tests/framework/service_project_alpha',
        })
        local first_request = support.submission('expiry-one')
        first_request.queue_lease_ms = 10
        local second_request = support.submission('expiry-two')
        second_request.queue_lease_ms = 100
        local first = admission.submit(controls.registry,
            first_project.project_id, first_request, dependencies)
        local second = admission.submit(controls.registry,
            second_project.project_id, second_request, dependencies)
        controls.set_time(111)
        local expired = queue.expire_due_queue(controls.registry, dependencies)
        assert.equals(first.identity.run_id, expired[1].identity.run_id)
        assert.same({second.identity.run_id}, controls.registry.queue)
    end)

    it('passes the stable cancel operation to operator authorization', function()
        local dependencies, controls = support.environment()
        local project = support.project(dependencies, 'operator-cancel')
        local admitted = admission.submit(controls.registry,
            project.project_id, support.submission('operator-cancel'),
            dependencies)
        queue.operator_cancel(controls.registry, {
            service_instance_id=admitted.identity.service_instance_id,
            project_id=admitted.identity.project_id,
            run_id=admitted.identity.run_id,
            generation=admitted.identity.generation,
            reason='operator cancellation', authority={allowed=true},
        }, dependencies)
        assert.same({'cancel'}, controls.authorization_operations)
    end)
end)
