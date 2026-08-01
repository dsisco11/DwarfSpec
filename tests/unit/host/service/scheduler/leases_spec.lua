-- Direct contracts for scheduler lease policy.

local admission = require('dwarfspec.host.service.scheduler.admission')
local leases = require('dwarfspec.host.service.scheduler.leases')
local queue = require('dwarfspec.host.service.scheduler.queue')
local OwnerKind = require('dwarfspec.protocol.enums.owner_kinds')
local support = assert(loadfile(
    'tests/unit/host/service/scheduler/support.lua'))()

describe('scheduler lease policy', function()
    it('renews only before expiry and replaces the expiry deadline', function()
        local dependencies, controls = support.environment()
        local project = support.project(dependencies, 'leases')
        local admitted = admission.submit(controls.registry,
            project.project_id, support.submission('leases'), dependencies)
        controls.set_time(200)
        leases.renew(controls.registry, support.owner_request(admitted),
            dependencies)
        assert.equals(200, admitted.run.queue_lease.renewed_at_ms)
        assert.equals(5200, admitted.run.queue_lease.expires_at_ms)
        controls.set_time(5200)
        assert.has_error(function() leases.renew(controls.registry,
            support.owner_request(admitted), dependencies) end,
            'run lease has already expired')
    end)

    it('replaces timers and ignores stale timer generations', function()
        local dependencies, controls = support.environment()
        local project = support.project(dependencies, 'timers')
        local admitted = admission.submit(controls.registry,
            project.project_id, support.submission('timers'), dependencies)
        leases.arm_timer(controls.registry, admitted.run, dependencies)
        local first_timer = admitted.run.lease_timer_id
        local stale_callback = controls.timers[first_timer].callback
        leases.arm_timer(controls.registry, admitted.run, dependencies)
        assert.same({first_timer}, controls.cancelled_timers)
        assert.is_true(admitted.run.lease_timer_id ~= first_timer)
        stale_callback()
        assert.is_nil(admitted.run.lease_timer_error)
        assert.is_true(admitted.run.lease_timer_id ~= first_timer)
    end)

    it('heartbeats in-process execution and claims expired external execution', function()
        local dependencies, controls = support.environment()
        local project = support.project(dependencies, 'heartbeat')
        local request = support.submission('heartbeat')
        request.owner_kind = OwnerKind.IN_PROCESS
        request.execution_lease_ms = 20
        local admitted = admission.submit(controls.registry,
            project.project_id, request, dependencies)
        queue.activate_next(controls.registry, dependencies)
        controls.set_time(110)
        leases.heartbeat(controls.registry, {
            service_instance_id=admitted.identity.service_instance_id,
            project_id=admitted.identity.project_id,
            run_id=admitted.identity.run_id,
            generation=admitted.identity.generation,
        }, dependencies)
        assert.equals(130, admitted.run.execution_lease.expires_at_ms)

        admitted.run.owner_kind = OwnerKind.EXTERNAL
        controls.set_time(130)
        assert.equals(admitted.run,
            leases.claim_expired_active(controls.registry, dependencies))
        assert.is_true(admitted.run.execution_lease.expiring)
    end)

    it('executes current timer policy and rearms renewable runs', function()
        local dependencies, controls = support.environment()
        local project = support.project(dependencies, 'timer-policy')
        local admitted = admission.submit(controls.registry,
            project.project_id, support.submission('timer-policy'), dependencies)
        leases.arm_timer(controls.registry, admitted.run, dependencies)
        local first_timer = admitted.run.lease_timer_id
        controls.timers[first_timer].callback()
        assert.equals(1, controls.expiry_calls)
        assert.is_true(admitted.run.lease_timer_id ~= first_timer)

        local second_dependencies, second_controls = support.environment()
        local second_project = support.project(second_dependencies,
            'timer-heartbeat')
        local request = support.submission('timer-heartbeat')
        request.owner_kind = OwnerKind.IN_PROCESS
        request.execution_lease_ms = 20
        local second = admission.submit(second_controls.registry,
            second_project.project_id, request, second_dependencies)
        queue.activate_next(second_controls.registry, second_dependencies)
        second_controls.set_time(110)
        leases.arm_timer(second_controls.registry, second.run,
            second_dependencies)
        local heartbeat_timer = second.run.lease_timer_id
        second_controls.timers[heartbeat_timer].callback()
        assert.equals(130, second.run.execution_lease.expires_at_ms)
        assert.is_true(second.run.lease_timer_id ~= heartbeat_timer)
    end)

    it('rejects stale generations before renewing any lease', function()
        local dependencies, controls = support.environment()
        local project = support.project(dependencies, 'stale')
        local admitted = admission.submit(controls.registry,
            project.project_id, support.submission('stale'), dependencies)
        local expires = admitted.run.queue_lease.expires_at_ms
        assert.has_error(function() leases.renew(controls.registry,
            support.owner_request(admitted, {
                generation=admitted.identity.generation + 1,
            }), dependencies) end)
        assert.equals(expires, admitted.run.queue_lease.expires_at_ms)
        assert.has_error(function() leases.renew(controls.registry,
            support.owner_request(admitted, {
                owner_capability='wrong-owner-capability',
            }), dependencies) end)
        assert.equals(expires, admitted.run.queue_lease.expires_at_ms)
    end)
end)
