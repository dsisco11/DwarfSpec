-- Direct contracts for scheduler admission policy.

local admission = require('dwarfspec.host.service.scheduler.admission')
local support = assert(loadfile(
    'tests/unit/host/service/scheduler/support.lua'))()

describe('scheduler admission', function()
    it('commits a queued record only after validation and reuses exact keys', function()
        local dependencies, controls = support.environment()
        local project = support.project(dependencies, 'admission')
        local request = support.submission('admission')
        local admitted = admission.submit(controls.registry,
            project.project_id, request, dependencies)
        local retry = admission.submit(controls.registry,
            project.project_id, request, dependencies)
        assert.is_true(admitted.accepted)
        assert.is_true(retry.reused)
        assert.equals(admitted.identity.run_id, retry.identity.run_id)
        assert.same({admitted.identity.run_id}, controls.registry.queue)
        local queued = admitted.run.event_journal.events[1]
        assert.equals(admitted.identity.run_id, queued.run_id)
        assert.equals(admitted.identity.generation, queued.generation)
    end)

    it('rejects project and result-path conflicts without partial mutation', function()
        local dependencies, controls = support.environment()
        local ResultPolicy = require('dwarfspec.protocol.enums.result_policies')
        local first_project = support.project(dependencies, 'first', {
            result_policy=ResultPolicy.FILE,
            result_path='tests/.test-results/direct-admission.json',
        })
        local first = admission.submit(controls.registry,
            first_project.project_id, support.submission('first'), dependencies)
        local busy = admission.submit(controls.registry,
            first_project.project_id, support.submission('busy'), dependencies)
        local second_project = support.project(dependencies, 'second', {
            project_root='.',
            result_policy=ResultPolicy.FILE,
            result_path='tests/framework/minimal_project/tests/.test-results/direct-admission.json',
        })
        local generation = controls.registry.generation
        local path_busy = admission.submit(controls.registry,
            second_project.project_id, support.submission('path'), dependencies)
        assert.is_false(busy.accepted)
        assert.is_false(path_busy.accepted)
        assert.equals(generation, controls.registry.generation)
        assert.same({first.identity.run_id}, controls.registry.queue)
    end)

    it('retries capability collisions and leaves invalid requests uncommitted', function()
        local dependencies, controls = support.environment()
        local first_project = support.project(dependencies, 'collision-one')
        local first = admission.submit(controls.registry,
            first_project.project_id, support.submission('collision-one'),
            dependencies)
        local attempts = 0
        dependencies.new_owner_capability = function()
            attempts = attempts + 1
            if attempts == 1 then return first.owner_capability end
            return 'replacement-owner-capability-0000000001'
        end
        local second_project = support.project(dependencies, 'collision-two', {
            project_root='tests/framework/service_project_alpha',
        })
        local second = admission.submit(controls.registry,
            second_project.project_id, support.submission('collision-two'),
            dependencies)
        assert.is_true(second.accepted)
        assert.equals(2, attempts)
        local generation = controls.registry.generation
        local invalid = support.submission('invalid')
        invalid.selection.identities = {'z', 'a'}
        assert.has_error(function() admission.submit(controls.registry,
            second_project.project_id, invalid, dependencies) end)
        assert.equals(generation, controls.registry.generation)
    end)
end)
