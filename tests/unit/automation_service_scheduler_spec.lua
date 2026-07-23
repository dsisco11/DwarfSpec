-- Unit contracts for multi-project admission and global FIFO scheduling.

local service = require('dwarfspec.automation.service')
local EventType = require('dwarfspec.automation.event_types')
local OwnerKind = require('dwarfspec.automation.owner_kinds')
local ResultPolicy = require('dwarfspec.automation.result_policies')
local RunState = require('dwarfspec.automation.run_states')
local SchedulerFailureKind =
    require('dwarfspec.automation.scheduler_failure_kinds')
local builders = assert(loadfile('tests/support/service_builders.lua'))()

local PROJECT_ROOTS = {
    'tests/framework/service_project_alpha',
    'tests/framework/service project beta',
    'tests/framework/minimal_project',
}

---Creates deterministic service dependencies and mutable test controls.
---@return table, table, table
local function environment()
    local namespace = {}
    local clock = builders.clock(100)
    local capability_sequence = 0
    local controls = {
        activation_rejection=nil,
        clean_state_verified=false,
    }
    local dependencies = {
        namespace=namespace,
        now_ms=clock.now_ms,
        new_service_instance_id=function()
            return 'service-scheduler-1'
        end,
        new_run_id=function(generation)
            return 'run-scheduler-' .. tostring(generation)
        end,
        new_owner_capability=function()
            capability_sequence = capability_sequence + 1
            return ('owner-capability-scheduler-%016d')
                :format(capability_sequence)
        end,
        validate_activation=function(project)
            local rejection = controls.activation_rejection
            if rejection and rejection.project_id == project.project_id then
                return false, rejection.reason
            end
            return true
        end,
        verify_clean_state=function(proof)
            return controls.clean_state_verified and proof.clean == true,
                'fixture clean-state proof was rejected'
        end,
        authorize_operator=function(authority)
            return authority.local_operator == true, 'fixture operator'
        end,
    }
    service.bootstrap({
        protocol_version=2,
        package_root='.',
        package_version='0.1.3',
    }, dependencies)
    return dependencies, clock, controls
end

---Registers one deterministic project session.
---@param dependencies table
---@param index integer
---@param overrides table|nil
---@return table
local function register_project(dependencies, index, overrides)
    local request = {
        project_root=PROJECT_ROOTS[index],
        display_name='Scheduler Project ' .. tostring(index),
        normalized_configuration={index=index},
        result_policy=ResultPolicy.FILE,
        result_path='tests/.test-results/dwarfspec/results.json',
        client_compatibility={
            protocol=2,
            package_version='0.1.3',
        },
    }
    for key, value in pairs(overrides or {}) do request[key] = value end
    return service.register_project(request, dependencies)
end

---Returns one deterministic valid run submission request.
---@param suffix string
---@return table
local function submission(suffix)
    return {
        request_key='request-key-' .. suffix .. '-00000001',
        owner_kind=OwnerKind.EXTERNAL,
        selection={
            identities={
                'tests/live/alpha.ds.lua',
                'tests/live/shared.ds.lua',
            },
        },
    }
end

---Builds an exact owner-authorized mutation request.
---@param admitted table
---@param overrides table|nil
---@return table
local function owner_request(admitted, overrides)
    local request = {
        service_instance_id=admitted.identity.service_instance_id,
        project_id=admitted.identity.project_id,
        run_id=admitted.identity.run_id,
        generation=admitted.identity.generation,
        owner_capability=admitted.owner_capability,
    }
    for key, value in pairs(overrides or {}) do request[key] = value end
    return request
end

---Returns event identifiers retained by one run.
---@param run_id string
---@param dependencies table
---@return string[]
local function event_types(run_id, dependencies)
    local result = {}
    for _, event in ipairs(service.events(run_id, 0, dependencies).events) do
        table.insert(result, event.type)
    end
    return result
end

---Registers three independent project sessions.
---@param dependencies table
---@return table[]
local function register_three(dependencies)
    return {
        register_project(dependencies, 1),
        register_project(dependencies, 2),
        register_project(dependencies, 3),
    }
end

---Asserts the registry has at most one executor-owning run.
---@param dependencies table
local function assert_executor_invariant(dependencies)
    local registry = dependencies.namespace.dwarfspec
    local owners = {}
    for _, run in pairs(registry.runs) do
        if not run.terminal and
                (run.state == RunState.STARTING or
                 run.state == RunState.RUNNING or
                 run.state == RunState.CLEANING) then
            table.insert(owners, run.run_id)
        end
    end
    assert.is_true(#owners <= 1)
    if registry.active_run_id == nil then
        assert.equals(0, #owners)
    else
        assert.same({registry.active_run_id}, owners)
    end
end

describe('multi-project automation service scheduler', function()
    it('builds canonical cursor transport from service-owned state',
            function()
        local dependencies = environment()
        local project = register_project(dependencies, 1)
        local admitted = service.submit(project.project_id,
            submission('transport'), dependencies)

        local initial = service.transport(admitted.identity.run_id, 0,
            dependencies)
        assert.equals('dwarfspec.transport.v2', initial.schema)
        assert.equals(2, initial.protocol)
        assert.equals(admitted.identity.service_instance_id,
            initial.service_instance_id)
        assert.equals(admitted.identity.project_id, initial.project_id)
        assert.equals(admitted.identity.run_id, initial.run_id)
        assert.equals(admitted.identity.generation, initial.generation)
        assert.equals(EventType.RUN_QUEUED, initial.events[1].type)
        assert.equals(1, initial.last_sequence)
        assert.equals(1, initial.snapshot.last_sequence)

        initial.snapshot.state = RunState.FAILED
        initial.events[1].payload.owner_kind = 'mutated'
        local next_read = service.transport(admitted.identity.run_id, 1,
            dependencies)
        assert.equals(RunState.QUEUED, next_read.snapshot.state)
        assert.same({}, next_read.events)
        assert.equals(1, next_read.last_sequence)
        assert.has_error(function()
            service.transport(admitted.identity.run_id, 2, dependencies)
        end, 'stale event cursor is ahead of journal: 2 > 1')
    end)

    it('retries a generated owner capability collision', function()
        local dependencies = environment()
        local projects = register_three(dependencies)
        local first = service.submit(projects[1].project_id,
            submission('collision-first'), dependencies)
        local attempts = 0
        dependencies.new_owner_capability = function()
            attempts = attempts + 1
            if attempts == 1 then return first.owner_capability end
            return 'owner-capability-after-collision-0001'
        end

        local second = service.submit(projects[2].project_id,
            submission('collision-second'), dependencies)

        assert.is_true(second.accepted)
        assert.equals(2, attempts)
        assert.equals('owner-capability-after-collision-0001',
            second.owner_capability)
    end)

    it('renews only an exact owner while observation remains read-only',
            function()
        local dependencies, clock = environment()
        local projects = register_three(dependencies)
        local request = submission('renew-owner')
        request.queue_lease_ms = 50
        request.execution_lease_ms = 80
        local admitted = service.submit(projects[1].project_id,
            request, dependencies)
        local before = service.snapshot(admitted.identity.run_id,
            dependencies)

        assert.is_nil(before.owner_capability)
        service.events(admitted.identity.run_id, 0, dependencies)
        assert.same(before, service.snapshot(admitted.identity.run_id,
            dependencies))

        for _, mutation in ipairs({
            {owner_capability='wrong-owner-capability-00000000001'},
            {generation=admitted.identity.generation + 1},
            {project_id=projects[2].project_id},
            {service_instance_id='other-service-instance'},
        }) do
            local unchanged = service.snapshot(admitted.identity.run_id,
                dependencies)
            assert.has_error(function()
                service.renew(owner_request(admitted, mutation), dependencies)
            end)
            assert.same(unchanged, service.snapshot(
                admitted.identity.run_id, dependencies))
        end

        clock.advance(10)
        local renewed = service.renew(owner_request(admitted), dependencies)
        assert.equals(before.queue_lease.expires_at_ms + 10,
            renewed.queue_lease.expires_at_ms)
        assert.equals(before.execution_lease.expires_at_ms,
            renewed.execution_lease.expires_at_ms)
    end)

    it('expires queued owners without cleanup and blocks only their project',
            function()
        local dependencies, clock = environment()
        local projects = register_three(dependencies)
        local request = submission('queued-expiry')
        request.queue_lease_ms = 20
        request.execution_lease_ms = 90
        local expired = service.submit(projects[1].project_id,
            request, dependencies)
        local cleanup_called = false
        dependencies.abort_active = function()
            cleanup_called = true
        end

        clock.advance(20)
        local outcome = service.expire_leases(dependencies)
        local retained = service.snapshot(expired.identity.run_id,
            dependencies)
        assert.same({expired.identity}, outcome.expired_queue)
        assert.is_false(cleanup_called)
        assert.equals(RunState.CANCELLED, retained.state)
        assert.is_true(retained.terminal)
        assert.is_true(retained.queue_lease.expired)
        assert.is_true(retained.cleanup_confirmed)

        local blocked = service.submit(projects[1].project_id,
            submission('same-project-blocked'), dependencies)
        assert.is_false(blocked.accepted)
        local other = service.submit(projects[2].project_id,
            submission('other-project-continues'), dependencies)
        assert.is_true(other.accepted)
        assert.equals(other.identity.run_id,
            service.activate_next(dependencies).identity.run_id)
    end)

    it('expires active owners through cleanup while another project continues',
            function()
        local dependencies, clock = environment()
        local projects = register_three(dependencies)
        local request = submission('active-expiry')
        request.queue_lease_ms = 15
        request.execution_lease_ms = 40
        local expired = service.submit(projects[1].project_id,
            request, dependencies)
        local active = service.activate_next(dependencies)
        local other = service.submit(projects[2].project_id,
            submission('after-active-expiry'), dependencies)
        local cleanup_identity
        dependencies.abort_active = function(identity, reason)
            cleanup_identity = identity
            service.complete_active(identity.run_id, identity.generation,
                RunState.ABORTED, true, reason, dependencies)
        end

        clock.advance(40)
        local outcome = service.expire_leases(dependencies)
        local retained = service.snapshot(expired.identity.run_id,
            dependencies)
        assert.same(active.identity, cleanup_identity)
        assert.same(active.identity, outcome.expired_active)
        assert.equals(RunState.ABORTED, retained.state)
        assert.is_true(retained.execution_lease.expired)
        assert.is_true(retained.cleanup_confirmed)
        assert.has_error(function()
            service.renew(owner_request(expired), dependencies)
        end)
        assert.equals(other.identity.run_id,
            service.activate_next(dependencies).identity.run_id)
    end)

    it('heartbeats in-process execution without a presentation owner',
            function()
        local dependencies, clock = environment()
        local project = register_project(dependencies, 1)
        local request = submission('in-process-heartbeat')
        request.owner_kind = OwnerKind.IN_PROCESS
        request.execution_lease_ms = 60
        local admitted = service.submit(project.project_id,
            request, dependencies)
        local active = service.activate_next(dependencies)
        assert.is_false(active.snapshot.queue_lease.active)
        assert.is_true(active.snapshot.execution_lease.service_owned)

        clock.advance(20)
        local renewed = service.heartbeat({
            service_instance_id=admitted.identity.service_instance_id,
            project_id=admitted.identity.project_id,
            run_id=admitted.identity.run_id,
            generation=admitted.identity.generation,
        }, dependencies)
        assert.equals(clock.now_ms() + 60,
            renewed.execution_lease.expires_at_ms)
    end)

    it('releases exact persisted results without clearing quarantine',
            function()
        local dependencies = environment()
        local projects = register_three(dependencies)
        local acknowledged = service.submit(projects[1].project_id,
            submission('acknowledged'), dependencies)
        local active = service.activate_next(dependencies)
        service.complete_active(active.identity.run_id,
            active.identity.generation, RunState.PASSED, true,
            'cleanup confirmed', dependencies)

        local acknowledgement = owner_request(acknowledged, {
            persistence={
                succeeded=true,
                policy=ResultPolicy.FILE,
                result_path=dependencies.namespace.dwarfspec.runs[
                    acknowledged.identity.run_id].result_path,
            },
        })
        local before = service.snapshot(acknowledged.identity.run_id,
            dependencies)
        acknowledgement.owner_capability =
            'wrong-owner-capability-00000000001'
        assert.has_error(function()
            service.acknowledge(acknowledgement, dependencies)
        end)
        assert.same(before, service.snapshot(
            acknowledged.identity.run_id, dependencies))
        acknowledgement.owner_capability = acknowledged.owner_capability
        assert.is_true(service.acknowledge(
            acknowledgement, dependencies).acknowledged)

        local discarded = service.submit(projects[2].project_id,
            submission('discarded'), dependencies)
        active = service.activate_next(dependencies)
        service.complete_active(active.identity.run_id,
            active.identity.generation, RunState.FAILED, false,
            'cleanup could not be confirmed', dependencies)
        local scheduler_before = service.scheduler_snapshot(dependencies)
        assert.is_true(scheduler_before.quarantine.active)
        local released = service.discard({
            service_instance_id=discarded.identity.service_instance_id,
            project_id=discarded.identity.project_id,
            run_id=discarded.identity.run_id,
            generation=discarded.identity.generation,
            reason='operator reviewed retained failure',
            authority={local_operator=true},
        }, dependencies)
        assert.is_true(released.discarded)
        assert.is_true(service.scheduler_snapshot(
            dependencies).quarantine.active)
        local types = event_types(discarded.identity.run_id, dependencies)
        assert.equals(EventType.DIAGNOSTIC_RECORDED, types[#types])
    end)

    it('activates three projects in FIFO order with one executor owner',
            function()
        local dependencies, clock = environment()
        local projects = register_three(dependencies)
        local admitted = {
            service.submit(projects[1].project_id,
                submission('1'), dependencies),
        }
        assert.equals(1, admitted[1].snapshot.queue_position)
        local first_active = service.activate_next(dependencies)
        assert.is_true(first_active.activated)
        assert_executor_invariant(dependencies)

        admitted[2] = service.submit(projects[2].project_id,
            submission('2'), dependencies)
        assert.is_true(admitted[2].accepted)
        assert.equals(1, admitted[2].snapshot.queue_position)
        clock.advance(10)
        service.complete_active(first_active.identity.run_id,
            first_active.identity.generation, RunState.PASSED, true,
            'cleanup confirmed', dependencies)
        assert_executor_invariant(dependencies)

        admitted[3] = service.submit(projects[3].project_id,
            submission('3'), dependencies)
        assert.is_true(admitted[3].accepted)
        assert.equals(2, admitted[3].snapshot.queue_position)

        local activated_order = {first_active.identity.run_id}
        for index = 2, 3 do
            local expected = admitted[index]
            clock.advance(10)
            local activated = service.activate_next(dependencies)
            assert.is_true(activated.activated)
            assert_executor_invariant(dependencies)
            table.insert(activated_order, activated.identity.run_id)
            assert.equals(expected.identity.run_id,
                activated.identity.run_id)
            assert.equals(RunState.STARTING, activated.snapshot.state)

            local blocked = service.activate_next(dependencies)
            assert.is_false(blocked.activated)
            assert.equals(SchedulerFailureKind.EXECUTOR_BUSY,
                blocked.kind)
            assert.equals(expected.identity.run_id,
                blocked.identity.run_id)
            assert_executor_invariant(dependencies)

            clock.advance(10)
            local finished = service.complete_active(
                activated.identity.run_id,
                activated.identity.generation,
                RunState.PASSED, true, 'cleanup confirmed',
                dependencies)
            assert.is_true(finished.finished)
            assert.is_nil(finished.scheduler.active_run_id)
            assert.is_false(finished.scheduler.quarantine.active)
            assert_executor_invariant(dependencies)
            assert.equals(expected.identity.run_id,
                service.project(projects[index].project_id,
                    dependencies).outstanding_run_id)
        end
        assert.same({
            admitted[1].identity.run_id,
            admitted[2].identity.run_id,
            admitted[3].identity.run_id,
        }, activated_order)
    end)

    it('prevents project flooding and preserves idempotent retry identity',
            function()
        local dependencies = environment()
        local projects = register_three(dependencies)
        local first = service.submit(projects[1].project_id,
            submission('alpha'), dependencies)
        local retry = service.submit(projects[1].project_id,
            submission('alpha'), dependencies)
        assert.is_true(retry.accepted)
        assert.is_true(retry.reused)
        assert.equals(first.identity.run_id, retry.identity.run_id)
        assert.equals(first.owner_capability, retry.owner_capability)
        assert.is_nil(first.snapshot.owner_capability)
        assert.is_nil(service.events(first.identity.run_id, 0,
            dependencies).events[1].owner_capability)

        local mismatched_retry = submission('alpha')
        mismatched_retry.selection.identities = {'tests/live/other.ds.lua'}
        local conflict = service.submit(projects[1].project_id,
            mismatched_retry, dependencies)
        assert.is_false(conflict.accepted)
        assert.equals(SchedulerFailureKind.REQUEST_KEY_CONFLICT,
            conflict.kind)
        assert.equals(first.identity.run_id, conflict.identity.run_id)

        local busy = service.submit(projects[1].project_id,
            submission('alpha-other'), dependencies)
        assert.is_false(busy.accepted)
        assert.equals(SchedulerFailureKind.PROJECT_BUSY, busy.kind)
        assert.equals(first.identity.run_id, busy.identity.run_id)

        local second = service.submit(projects[2].project_id,
            submission('alpha'), dependencies)
        local third = service.submit(projects[3].project_id,
            submission('gamma'), dependencies)
        local queue = service.scheduler_snapshot(dependencies).queue
        assert.same({
            {run_id=first.identity.run_id,
                project_id=projects[1].project_id},
            {run_id=second.identity.run_id,
                project_id=projects[2].project_id},
            {run_id=third.identity.run_id,
                project_id=projects[3].project_id},
        }, queue)
        assert_executor_invariant(dependencies)
    end)

    it('rejects colliding result paths without partially admitting a run',
            function()
        local dependencies = environment()
        local shared = 'D:/shared scheduler output/results.json'
        local alpha = register_project(dependencies, 1, {
            result_path=shared,
        })
        local beta = register_project(dependencies, 2, {
            result_path='D:\\shared scheduler output\\.\\results.json',
        })
        local first = service.submit(alpha.project_id,
            submission('collision-alpha'), dependencies)
        local before = service.summary(dependencies)
        local collision = service.submit(beta.project_id,
            submission('collision-beta'), dependencies)

        assert.is_false(collision.accepted)
        assert.equals(SchedulerFailureKind.RESULT_PATH_BUSY,
            collision.kind)
        assert.equals(first.identity.run_id, collision.identity.run_id)
        assert.same(before, service.summary(dependencies))

        local invalid = submission('invalid-selection')
        invalid.selection.identities = {'z.ds.lua', 'a.ds.lua'}
        assert.has_error(function()
            service.submit(beta.project_id, invalid, dependencies)
        end, 'run selection identities must be sorted and unique')
        assert.same(before, service.summary(dependencies))

        local unsafe = submission('unsafe-request')
        unsafe.callback=function() end
        assert.has_error(function()
            service.submit(beta.project_id, unsafe, dependencies)
        end, 'JSON-safe value run submission request.callback has ' ..
            'unsupported type function')
        assert.same(before, service.summary(dependencies))

        local escaping = register_project(dependencies, 3, {
            result_path='../outside-project/results.json',
        })
        local after_registration = service.summary(dependencies)
        assert.has_error(function()
            service.submit(escaping.project_id,
                submission('escaping-path'), dependencies)
        end, 'relative file path must remain beneath its project root')
        assert.same(after_registration, service.summary(dependencies))

        local active = service.activate_next(dependencies)
        service.complete_active(active.identity.run_id,
            active.identity.generation, RunState.PASSED, true,
            'cleanup confirmed', dependencies)
        local retained_collision = service.submit(beta.project_id,
            submission('collision-after-terminal'), dependencies)
        assert.is_false(retained_collision.accepted)
        assert.equals(SchedulerFailureKind.RESULT_PATH_BUSY,
            retained_collision.kind)
        assert.equals(first.identity.run_id,
            retained_collision.identity.run_id)
    end)

    it('cancels a queued run with a complete non-native terminal journal',
            function()
        local dependencies, clock = environment()
        local projects = register_three(dependencies)
        local first = service.submit(projects[1].project_id,
            submission('cancel-alpha'), dependencies)
        local second = service.submit(projects[2].project_id,
            submission('cancel-beta'), dependencies)
        dependencies.native_cleanup=function()
            error('queued cancellation must not invoke native cleanup')
        end
        clock.advance(5)

        local cancelled = service.cancel({
            service_instance_id=first.identity.service_instance_id,
            project_id=first.identity.project_id,
            run_id=first.identity.run_id,
            generation=first.identity.generation,
            owner_capability=first.owner_capability,
            reason='caller cancelled while queued',
        }, dependencies)
        assert.is_true(cancelled.cancelled)
        assert.equals(RunState.CANCELLED, cancelled.snapshot.state)
        assert.is_true(cancelled.snapshot.terminal)
        assert.is_true(cancelled.snapshot.cleanup_confirmed)
        assert.is_nil(cancelled.snapshot.queue_position)
        assert.same({
            EventType.RUN_QUEUED,
            EventType.RUN_CANCELLED,
            EventType.RUN_FINISHED,
        }, event_types(first.identity.run_id, dependencies))
        assert.equals(1, service.snapshot(second.identity.run_id,
            dependencies).queue_position)
        assert.same({EventType.RUN_QUEUED},
            event_types(second.identity.run_id, dependencies))
        assert.is_true(service.activate_next(dependencies).activated)
        assert_executor_invariant(dependencies)
    end)

    it('quarantines activation while preserving observation and cancel',
            function()
        local dependencies, clock, controls = environment()
        local projects = register_three(dependencies)
        local first = service.submit(projects[1].project_id,
            submission('quarantine-alpha'), dependencies)
        local second = service.submit(projects[2].project_id,
            submission('quarantine-beta'), dependencies)
        clock.advance(5)
        local active = service.activate_next(dependencies)
        clock.advance(5)
        service.complete_active(active.identity.run_id,
            active.identity.generation, RunState.FAILED, false,
            'fixture cleanup leak', dependencies)
        assert_executor_invariant(dependencies)

        local scheduler = service.scheduler_snapshot(dependencies)
        assert.is_nil(scheduler.active_run_id)
        assert.is_true(scheduler.quarantine.active)
        assert.equals('fixture cleanup leak', scheduler.quarantine.reason)
        assert.same({
            EventType.RUN_QUEUED,
            EventType.SCHEDULER_BLOCKED,
        }, event_types(second.identity.run_id, dependencies))
        assert.equals(scheduler.quarantine.reason,
            service.events(second.identity.run_id, 0,
                dependencies).events[2].payload.reason)

        local third = service.submit(projects[3].project_id,
            submission('quarantine-gamma'), dependencies)
        assert.is_true(third.accepted)
        assert.same({
            EventType.RUN_QUEUED,
            EventType.SCHEDULER_BLOCKED,
        }, event_types(third.identity.run_id, dependencies))
        assert.equals(scheduler.quarantine.reason,
            service.events(third.identity.run_id, 0,
                dependencies).events[2].payload.reason)
        local blocked = service.activate_next(dependencies)
        assert.is_false(blocked.activated)
        assert.equals(SchedulerFailureKind.EXECUTOR_QUARANTINED,
            blocked.kind)

        clock.advance(5)
        assert.is_true(service.cancel({
            service_instance_id=second.identity.service_instance_id,
            project_id=second.identity.project_id,
            run_id=second.identity.run_id,
            generation=second.identity.generation,
            owner_capability=second.owner_capability,
            reason='cancel while quarantined',
        }, dependencies).cancelled)
        assert_executor_invariant(dependencies)
        assert.equals(1, service.snapshot(third.identity.run_id,
            dependencies).queue_position)

        assert.has_error(function()
            service.recover_executor({
                service_instance_id=scheduler.service_instance_id,
                run_id=scheduler.quarantine.run_id,
                generation=scheduler.quarantine.generation + 1,
                reason='stale recovery',
                proof={clean=true},
            }, dependencies)
        end, 'executor recovery generation does not match quarantine')
        assert.has_error(function()
            service.recover_executor({
                service_instance_id=scheduler.service_instance_id,
                run_id=scheduler.quarantine.run_id,
                generation=scheduler.quarantine.generation,
                reason='unverified recovery',
                proof={clean=true},
            }, dependencies)
        end, 'fixture clean-state proof was rejected')
        assert.is_true(service.scheduler_snapshot(
            dependencies).quarantine.active)

        controls.clean_state_verified = true
        local recovered = service.recover_executor({
            service_instance_id=scheduler.service_instance_id,
            run_id=scheduler.quarantine.run_id,
            generation=scheduler.quarantine.generation,
            reason='verified recovery',
            proof={clean=true, source='fixture lifecycle probe'},
        }, dependencies)
        assert.is_true(recovered.recovered)
        assert.is_false(recovered.scheduler.quarantine.active)
        assert.is_true(service.activate_next(dependencies).activated)
        assert_executor_invariant(dependencies)
        assert.equals(first.identity.run_id,
            service.project(projects[1].project_id,
                dependencies).outstanding_run_id)
    end)

    it('revalidates registration, compatibility, selection, and paths',
            function()
        local cases = {
            {
                name='registration',
                mutate=function(registry, project)
                    registry.projects[project.project_id] = nil
                end,
            },
            {
                name='compatibility',
                mutate=function(registry, project)
                    registry.projects[project.project_id].
                        client_compatibility.package_version = 'incompatible'
                end,
            },
            {
                name='selection',
                mutate=function(registry, project, run)
                    run.selection.identities = {'z.ds.lua', 'a.ds.lua'}
                end,
            },
            {
                name='project-path',
                mutate=function(registry, project)
                    registry.projects[project.project_id].
                        normalized_project_root =
                        project.normalized_project_root .. '/missing'
                end,
            },
            {
                name='result-path',
                mutate=function(registry, project)
                    registry.projects[project.project_id].result_path =
                        'other/results.json'
                end,
            },
        }
        for _, case in ipairs(cases) do
            local dependencies, clock = environment()
            local project = register_project(dependencies, 1)
            local first = service.submit(project.project_id,
                submission('revalidate-' .. case.name), dependencies)
            local run = dependencies.namespace.dwarfspec.runs[
                first.identity.run_id]
            case.mutate(dependencies.namespace.dwarfspec, project, run)
            clock.advance(5)

            local rejected = service.activate_next(dependencies)
            assert.is_false(rejected.activated)
            assert.equals(SchedulerFailureKind.ACTIVATION_INVALID,
                rejected.kind)
            assert.equals(RunState.FAILED, rejected.snapshot.state)
            assert.is_true(rejected.snapshot.terminal)
            assert.is_nil(service.scheduler_snapshot(
                dependencies).active_run_id)
            assert.same({
                EventType.RUN_QUEUED,
                EventType.SCHEDULER_BLOCKED,
                EventType.RUN_FINISHED,
            }, event_types(first.identity.run_id, dependencies))
            assert_executor_invariant(dependencies)
        end

        local dependencies, clock, controls = environment()
        local project = register_project(dependencies, 1)
        local first = service.submit(project.project_id,
            submission('revalidate-catalog'), dependencies)
        controls.activation_rejection = {
            project_id=project.project_id,
            reason='fixture catalog selection is stale',
        }
        clock.advance(5)
        assert.equals(SchedulerFailureKind.ACTIVATION_INVALID,
            service.activate_next(dependencies).kind)
        assert.same({
            EventType.RUN_QUEUED,
            EventType.SCHEDULER_BLOCKED,
            EventType.RUN_FINISHED,
        }, event_types(first.identity.run_id, dependencies))
    end)
end)
