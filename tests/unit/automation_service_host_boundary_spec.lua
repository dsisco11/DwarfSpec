-- Unit contracts for service-owned host transitions and stale callbacks.

local service = require('dwarfspec.automation.service')
local EventType = require('dwarfspec.automation.event_types')
local ResultPolicy = require('dwarfspec.automation.result_policies')
local RunState = require('dwarfspec.automation.run_states')
local TestStatus = require('dwarfspec.automation.test_statuses')

---Creates one deterministic service with an activated run.
---@return table, table
local function activated_run()
    local namespace = {}
    local tick = 0
    local dependencies = {
        namespace=namespace,
        now_ms=function()
            tick = tick + 1
            return tick
        end,
        new_service_instance_id=function()
            return 'service-host-boundary'
        end,
        new_run_id=function()
            return 'run-host-boundary'
        end,
        new_owner_capability=function()
            return 'owner-capability-host-boundary-00000001'
        end,
    }
    service.bootstrap({
        protocol_version=2,
        package_root='.',
        package_version='0.2.0',
    }, dependencies)
    local project = service.register_project({
        project_root='tests/framework/minimal_project',
        normalized_configuration={},
        result_policy=ResultPolicy.NONE,
        client_compatibility={protocol=2, package_version='0.2.0'},
    }, dependencies)
    local admitted = service.submit(project.project_id, {
        request_key='host-boundary-request-key',
        owner_kind='external',
        selection={identities={}},
    }, dependencies)
    local activated = service.activate_next(dependencies)
    assert.is_true(activated.activated)
    return dependencies, admitted.identity
end

---Returns retained event identifiers for one run.
---@param dependencies table
---@param run_id string
---@return string[]
local function event_types(dependencies, run_id)
    local result = {}
    for _, event in ipairs(service.events(run_id, 0,
            dependencies).events) do
        table.insert(result, event.type)
    end
    return result
end

describe('service-owned automation host boundary', function()
    it('drives active lifecycle and structured callback events', function()
        local dependencies, identity = activated_run()
        service.start_active(identity.run_id, identity.generation, {
            repeat_count=1,
            options={seed=1, shuffle=false},
        }, dependencies)
        service.publish_active_event(identity.run_id, identity.generation,
            EventType.REPEAT_STARTED, {
                repeat_index=1,
                repeat_count=1,
            }, dependencies)
        service.publish_active_event(identity.run_id, identity.generation,
            EventType.TEST_STARTED, {
                name='service-owned test',
                source_identity='tests/live/example.ds.lua',
            }, dependencies)
        service.publish_active_event(identity.run_id, identity.generation,
            EventType.TEST_FINISHED, {
                name='service-owned test',
                status=TestStatus.FAILURE,
                duration_ms=2,
            }, dependencies)
        service.publish_active_event(identity.run_id, identity.generation,
            EventType.PROBLEM_RECORDED, {
                kind='failure',
                name='service-owned test',
                message='originating assertion',
            }, dependencies)
        service.begin_cleanup(identity.run_id, identity.generation,
            'suite completion', 1, dependencies)
        service.publish_active_event(identity.run_id, identity.generation,
            EventType.CLEANUP_FAILED, {
                action_name='fixture cleanup',
                reason='suite completion',
                message='cleanup also failed',
            }, dependencies)
        service.publish_active_event(identity.run_id, identity.generation,
            EventType.CLEANUP_FINISHED, {
                cleanup_confirmed=false,
                mount_cleanup_verified=true,
            }, dependencies)
        service.complete_active(identity.run_id, identity.generation,
            RunState.FAILED, false, 'cleanup also failed', dependencies)

        assert.same({
            EventType.RUN_QUEUED,
            EventType.RUN_ACTIVATED,
            EventType.RUN_STARTED,
            EventType.REPEAT_STARTED,
            EventType.TEST_STARTED,
            EventType.TEST_FINISHED,
            EventType.PROBLEM_RECORDED,
            EventType.CLEANUP_STARTED,
            EventType.CLEANUP_FAILED,
            EventType.CLEANUP_FINISHED,
            EventType.RUN_FINISHED,
        }, event_types(dependencies, identity.run_id))
        local snapshot = service.snapshot(identity.run_id, dependencies)
        assert.equals(RunState.FAILED, snapshot.state)
        assert.is_true(snapshot.terminal)
        assert.is_false(snapshot.cleanup_confirmed)
        assert.is_true(service.scheduler_snapshot(
            dependencies).quarantine.active)
    end)

    it('rejects stale scheduled, callback, cleanup, and terminal identities',
            function()
        local dependencies, identity = activated_run()
        assert.has_error(function()
            service.start_active(identity.run_id, identity.generation + 1, {
                repeat_count=1,
                options={},
            }, dependencies)
        end, 'active executor generation does not match start')
        service.start_active(identity.run_id, identity.generation, {
            repeat_count=1,
            options={},
        }, dependencies)
        service.begin_cleanup(identity.run_id, identity.generation,
            'suite completion', 0, dependencies)
        service.publish_active_event(identity.run_id, identity.generation,
            EventType.CLEANUP_FINISHED, {
                cleanup_confirmed=true,
                mount_cleanup_verified=true,
            }, dependencies)
        service.complete_active(identity.run_id, identity.generation,
            RunState.PASSED, true, 'suite completion', dependencies)
        local before = service.events(identity.run_id, 0,
            dependencies).last_sequence

        assert.has_error(function()
            service.publish_active_event(identity.run_id,
                identity.generation, EventType.DIAGNOSTIC_RECORDED, {
                    kind='stale',
                    content={},
                }, dependencies)
        end, 'event publisher no longer owns the active executor')
        assert.has_error(function()
            service.complete_active(identity.run_id,
                identity.generation, RunState.FAILED, true,
                'stale terminal callback', dependencies)
        end, 'active executor identity does not match completion')
        assert.equals(before, service.events(identity.run_id, 0,
            dependencies).last_sequence)
    end)
end)
