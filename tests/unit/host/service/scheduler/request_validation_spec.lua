-- Direct contracts for mutation-free scheduler request validation.

local validation = require('dwarfspec.host.service.scheduler.request_validation')
local support = assert(loadfile(
    'tests/unit/host/service/scheduler/support.lua'))()

describe('scheduler request validation', function()
    it('detaches selections and rejects malformed identities without mutation', function()
        local dependencies, controls = support.environment()
        local project = support.project(dependencies, 'validation')
        local request = support.submission('validation')
        local normalized = validation.submission(controls.registry,
            project.project_id, request, dependencies)
        normalized.selection.identities[1] = 'changed'
        assert.equals('tests/live/example.ds.lua', request.selection.identities[1])
        request.selection.identities = {'z', 'a'}
        assert.has_error(function() validation.submission(controls.registry,
            project.project_id, request, dependencies) end)
        assert.same({}, controls.registry.runs)
    end)

    it('matches idempotent requests and rejects owner or operator impostors', function()
        local dependencies, controls = support.environment()
        local project = support.project(dependencies, 'authority')
        local request = support.submission('authority')
        local normalized = validation.submission(controls.registry,
            project.project_id, request, dependencies)
        local run = {
            service_instance_id=controls.registry.service_instance_id,
            project_id=project.project_id,
            run_id='validation-run', generation=1,
            owner_kind=normalized.owner_kind,
            owner_capability='validation-owner',
            queue_lease={timeout_ms=normalized.queue_lease_ms},
            execution_lease={timeout_ms=normalized.execution_lease_ms},
            lease_check_frames=normalized.lease_check_frames,
            result_path_identity=normalized.result_path_identity,
            result_policy=normalized.project.result_policy,
            selection=normalized.selection,
        }
        controls.registry.runs[run.run_id] = run
        project.outstanding_run_id = run.run_id
        assert.is_true(validation.matches_request_key(run, normalized))
        local owner = support.owner_request({identity=validation.public_identity(run),
            owner_capability='wrong-owner'})
        assert.has_error(function() validation.authorize_owner(
            controls.registry, owner, 'renewal') end)
        assert.has_error(function() validation.authorize_operator(dependencies,
            {authority={allowed=false}}, 'abort', run) end,
            'direct operator')
        assert.same({'abort'}, controls.authorization_operations)
    end)

    it('normalizes result paths and finds outstanding reservations', function()
        local dependencies, controls = support.environment()
        local project = support.project(dependencies, 'result-path', {
            result_policy=require('dwarfspec.protocol.enums.result_policies').FILE,
            result_path='tests/.test-results/direct-validation.json',
        })
        local normalized = validation.submission(controls.registry,
            project.project_id, support.submission('result-path'), dependencies)
        local run = {result_path_identity=normalized.result_path_identity}
        controls.registry.runs.reserved = run
        assert.equals(run, validation.find_result_path_owner(
            controls.registry, normalized.result_path_identity))
        run.acknowledged = true
        assert.is_nil(validation.find_result_path_owner(
            controls.registry, normalized.result_path_identity))
    end)
end)
