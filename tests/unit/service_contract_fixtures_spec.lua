-- Unit contracts for Phase 0 multi-project builders and schema fixtures.

local json = require('dkjson')
local lfs = require('lfs')
local project = require('dwarfspec.project')
local runner = require('dwarfspec.runner')
local builders = assert(loadfile('tests/support/service_builders.lua'))()

local fixture_root = 'tests/framework/fixtures/service_v2'

---Reads and decodes one checked-in JSON contract fixture.
---@param name string
---@return table, string
local function read_fixture(name)
    local path = project.join(fixture_root, name)
    local file = assert(io.open(path, 'rb'))
    local contents = assert(file:read('*a'))
    file:close()
    local value, _, decode_error = json.decode(contents)
    assert(value, decode_error)
    return value, contents
end

---Asserts recursively that no owner capability leaked into contract data.
---@param value any
local function assert_no_owner_capability(value)
    if type(value) ~= 'table' then return end
    for key, child in pairs(value) do
        assert.is_not.equals('owner_capability', key)
        assert_no_owner_capability(child)
    end
end

describe('multi-project service contract fixtures', function()
    it('provides independent deterministic record builders', function()
        local identifiers = builders.identifiers('contract', 7)
        assert.equals('project-contract-7', identifiers.next('project'))
        assert.equals('run-contract-8', identifiers.next('run'))

        local first_project = builders.project()
        local second_project = builders.project({
            project_id='project-fixture-2',
        })
        first_project.normalized_configuration.changed = true
        assert.is_nil(second_project.normalized_configuration.changed)

        local first_run = builders.run()
        local second_run = builders.run({run_id='run-fixture-2'})
        table.insert(first_run.events, {type='run.queued'})
        assert.equals(0, #second_run.events)

        local first_registry = builders.registry()
        local second_registry = builders.registry()
        first_registry.projects.alpha = first_project
        assert.is_nil(second_registry.projects.alpha)
    end)

    it('provides a deterministic fake clock and callback scheduler', function()
        local clock = builders.clock(100)
        local scheduler = builders.scheduler(clock)
        local observed = {}
        local late = scheduler.schedule(10, function()
            table.insert(observed, 'late')
        end)
        scheduler.schedule(5, function()
            table.insert(observed, 'first')
        end)
        scheduler.schedule(5, function()
            table.insert(observed, 'second')
        end)

        assert.equals(3, scheduler.pending_count())
        assert.is_nil(scheduler.run_next())
        clock.advance(5)
        assert.equals(2, scheduler.run_next())
        assert.equals(3, scheduler.run_next())
        assert.same({'first', 'second'}, observed)
        assert.is_true(scheduler.cancel(late))
        assert.is_false(scheduler.cancel(late))
        assert.equals(0, scheduler.pending_count())
    end)

    it('provides distinct roots with a shared spec identity and result path',
            function()
        local filesystem = project.filesystem()
        local current_directory = lfs.currentdir()
        local alpha = project.resolve_root(
            'tests/framework/service_project_alpha',
            current_directory, filesystem)
        local beta = project.resolve_root(
            'tests/framework/service project beta',
            current_directory, filesystem)
        local identity = 'tests/live/shared_spec.ds.lua'
        local alpha_result = project.join(alpha,
            'tests/.test-results/dwarfspec/results.json')
        local beta_result = project.join(beta,
            'tests/.test-results/dwarfspec/results.json')

        assert.is_not.equals(alpha, beta)
        assert.matches('service project beta', beta, 1, true)
        assert.same({identity}, project.discover(alpha, filesystem,
            'tests/live/*.ds.lua'))
        assert.same({identity}, project.discover(beta, filesystem,
            'tests/live/*.ds.lua'))
        assert.is_not.equals(project.normalize(alpha_result),
            project.normalize(beta_result))
    end)

    it('decodes representative version 2 result outcomes', function()
        local expected = {
            result_queued={state='queued', terminal=false},
            result_running={state='running', terminal=false},
            result_passed={state='passed', terminal=true},
            result_failed={state='failed', terminal=true},
            result_aborted={state='aborted', terminal=true},
            result_cancelled={state='cancelled', terminal=true},
            result_dependency_error={
                state='dependency_error',
                terminal=true,
            },
        }

        for name, contract in pairs(expected) do
            local fixture, contents = read_fixture(name .. '.json')
            assert.equals('dwarfspec.result.v2', fixture.schema)
            assert.equals(contract.state, fixture.state)
            assert.equals(contract.terminal, fixture.terminal)
            assert.is_table(fixture.selection)
            assert.is_table(fixture.events)
            assert.is_string(fixture.project_root)
            assert.is_nil(contents:lower():find('"ui"', 1, true))
            assert.is_nil(contents:lower():find('"widget"', 1, true))
            assert_no_owner_capability(fixture)
        end
    end)

    it('decodes a quarantined scheduler outcome without UI state', function()
        local fixture, contents = read_fixture(
            'scheduler_quarantined.json')

        assert.equals('dwarfspec.scheduler.v2', fixture.schema)
        assert.is_true(fixture.quarantine.active)
        assert.equals(1, #fixture.queue)
        assert.equals(2, #fixture.projects)
        assert.is_nil(contents:lower():find('"ui"', 1, true))
        assert.is_nil(contents:lower():find('"widget"', 1, true))
        assert_no_owner_capability(fixture)
    end)

    it('maps every existing exit code to version 2 states', function()
        local fixture = read_fixture('exit_code_map.json')
        local by_kind = {}
        local by_code = {}
        for _, mapping in ipairs(fixture.mappings) do
            assert.is_nil(by_kind[mapping.kind])
            assert.is_nil(by_code[mapping.exit_code])
            assert.is_true(#mapping.states >= 1)
            by_kind[mapping.kind] = mapping
            by_code[mapping.exit_code] = mapping
        end

        local count = 0
        for kind, exit_code in pairs(runner.exit_codes) do
            count = count + 1
            assert.equals(exit_code, by_kind[kind].exit_code)
        end
        assert.equals(count, #fixture.mappings)
        assert.equals('dwarfspec.exit-code-map.v1', fixture.schema)
    end)
end)
