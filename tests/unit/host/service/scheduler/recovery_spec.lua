-- Direct contracts for scheduler recovery policy.

local admission = require('dwarfspec.host.service.scheduler.admission')
local recovery = require('dwarfspec.host.service.scheduler.recovery')
local queue = require('dwarfspec.host.service.scheduler.queue')
local transitions = require('dwarfspec.host.service.scheduler.transitions')
local RunState = require('dwarfspec.protocol.enums.run_states')
local support = assert(loadfile(
    'tests/unit/host/service/scheduler/support.lua'))()

describe('scheduler recovery policy', function()
    it('requires exact quarantine identity and authoritative clean-state proof', function()
        local dependencies, controls = support.environment()
        local project = support.project(dependencies, 'recovery')
        local admitted = admission.submit(controls.registry,
            project.project_id, support.submission('recovery'), dependencies)
        controls.registry.quarantine = {active=true,
            run_id=admitted.identity.run_id,
            generation=admitted.identity.generation, reason='unclean'}
        local request = {service_instance_id=admitted.identity.service_instance_id,
            run_id=admitted.identity.run_id,
            generation=admitted.identity.generation,
            reason='verified clean', proof={clean=true}}
        assert.same({recovered=true}, recovery.recover_executor(
            controls.registry, request, dependencies))
        assert.is_false(controls.registry.quarantine.active)
    end)

    it('rejects failed clean-state proof without clearing quarantine', function()
        local dependencies, controls = support.environment()
        controls.registry.quarantine = {active=true,
            run_id='failed-proof', generation=3, reason='unclean'}
        assert.has_error(function() recovery.recover_executor(controls.registry,
            {service_instance_id=controls.registry.service_instance_id,
                run_id='failed-proof', generation=3,
                reason='not clean', proof={clean=false}}, dependencies) end,
            'clean-state proof rejected')
        assert.is_true(controls.registry.quarantine.active)
    end)

    it('authorizes owner and operator abort with stable operation identity', function()
        local dependencies, controls = support.environment()
        local project = support.project(dependencies, 'abort')
        local admitted = admission.submit(controls.registry,
            project.project_id, support.submission('abort'), dependencies)
        queue.activate_next(controls.registry, dependencies)
        assert.equals(admitted.run, recovery.authorize_abort(controls.registry,
            support.owner_request(admitted, {reason='owner abort'})))
        assert.has_error(function() recovery.authorize_abort(controls.registry,
            support.owner_request(admitted, {
                generation=admitted.identity.generation + 1,
                reason='stale abort',
            })) end)
        assert.equals(admitted.run, recovery.authorize_operator_abort(
            controls.registry, {
                service_instance_id=admitted.identity.service_instance_id,
                project_id=admitted.identity.project_id,
                run_id=admitted.identity.run_id,
                generation=admitted.identity.generation,
                reason='operator abort', authority={allowed=true},
            }, dependencies))
        assert.same({'abort'}, controls.authorization_operations)
    end)

    it('acknowledges or discards exact terminal results and releases reservations', function()
        local dependencies, controls = support.environment()
        local project = support.project(dependencies, 'acknowledge')
        local admitted = admission.submit(controls.registry,
            project.project_id, support.submission('acknowledge'), dependencies)
        transitions.cancel_queued(controls.registry, admitted.run,
            'cancelled', 'external', 200)
        recovery.acknowledge(controls.registry,
            support.owner_request(admitted, {persistence={
                succeeded=true,
                policy=require('dwarfspec.protocol.enums.result_policies').NONE,
            }}), dependencies)
        assert.is_true(admitted.run.acknowledged)
        assert.is_nil(project.outstanding_run_id)

        local discard_project = support.project(dependencies, 'discard', {
            project_root='tests/framework/service_project_alpha',
        })
        local discarded = admission.submit(controls.registry,
            discard_project.project_id, support.submission('discard'), dependencies)
        transitions.cancel_queued(controls.registry, discarded.run,
            'cancelled', 'external', 210)
        recovery.discard(controls.registry, {
            service_instance_id=discarded.identity.service_instance_id,
            project_id=discarded.identity.project_id,
            run_id=discarded.identity.run_id,
            generation=discarded.identity.generation,
            reason='operator discard', authority={allowed=true},
        }, dependencies)
        assert.is_true(discarded.run.discarded)
        assert.is_nil(discard_project.outstanding_run_id)
        assert.same({'discard'}, controls.authorization_operations)
    end)
end)
