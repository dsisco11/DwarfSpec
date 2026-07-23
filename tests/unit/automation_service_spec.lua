-- Unit contracts for the multi-project automation service runtime.

local projects = require('dwarfspec.automation.projects')
local events = require('dwarfspec.automation.events')
local EventType = require('dwarfspec.automation.event_types')
local service_path = 'src/dwarfspec/automation/service.lua'

describe('multi-project automation service', function()
    local namespace
    local directories
    local current_time
    local dependencies
    local service

    ---Returns a normalized case-insensitive fake filesystem key.
    ---@param path string
    ---@return string
    local function path_key(path)
        return path:gsub('\\', '/'):gsub('/+', '/'):lower()
    end

    ---Returns a valid service bootstrap request.
    ---@param package_root string|nil
    ---@param package_version string|nil
    ---@return table
    local function bootstrap_request(package_root, package_version)
        return {
            protocol_version=2,
            package_root=package_root or 'D:/Packages/DwarfSpec',
            package_version=package_version or '0.1.3',
        }
    end

    ---Returns a valid project registration request.
    ---@param root string
    ---@param overrides table|nil
    ---@return table
    local function registration(root, overrides)
        local request = {
            project_root=root,
            display_name='Fixture Project',
            normalized_configuration={
                filters={'fast'},
                support_module='consumer.phase1_should_not_load',
            },
            result_path=root:gsub('\\', '/') ..
                '/tests/.test-results/dwarfspec/results.json',
            result_policy='file',
            client_compatibility={
                protocol=2,
                package_version='0.1.3',
            },
        }
        for key, value in pairs(overrides or {}) do request[key] = value end
        return request
    end

    before_each(function()
        namespace = {}
        directories = {
            [path_key('D:/Packages/DwarfSpec')]=true,
            [path_key('D:/Packages/Other')]=true,
            [path_key('D:/Clients/Alpha')]=true,
            [path_key('D:/Clients/Beta')]=true,
            [path_key('D:/Clients/Project With Spaces')]=true,
        }
        current_time = 100
        dependencies = {
            namespace=namespace,
            filesystem={
                case_insensitive=true,
                currentdir=function()
                    return 'D:/Workspace'
                end,
                isdir=function(path)
                    return directories[path_key(path)] == true
                end,
            },
            now_ms=function()
                return current_time
            end,
            new_service_instance_id=function()
                return 'service-contract-1'
            end,
        }
        service = assert(loadfile(service_path))()
    end)

    it('bootstraps the complete process-wide registry without consumer loads',
            function()
        local consumer_loaded = false
        package.preload['consumer.phase1_should_not_load'] = function()
            consumer_loaded = true
            return {}
        end

        local summary = service.bootstrap(bootstrap_request(), dependencies)
        local registry = namespace.dwarfspec
        service.register_project(registration('D:/Clients/Alpha'),
            dependencies)
        package.preload['consumer.phase1_should_not_load'] = nil

        assert.equals('dwarfspec.service.v2', registry.schema)
        assert.equals(2, registry.protocol_version)
        assert.equals('service-contract-1', registry.service_instance_id)
        assert.equals('D:/Packages/DwarfSpec', registry.package_root)
        assert.equals('0.1.3', registry.package_version)
        assert.equals(0, registry.generation)
        assert.equals(2, registry.next_project_sequence)
        assert.is_table(registry.projects)
        assert.is_table(registry.runs)
        assert.is_table(registry.queue)
        assert.is_nil(registry.active_run_id)
        assert.same({active=false}, registry.quarantine)
        assert.is_table(registry.latest_terminal_results)
        assert.equals('service-contract-1', summary.service_instance_id)
        assert.is_false(consumer_loaded)
    end)

    it('normalizes and refreshes the same compatible project session',
            function()
        service.bootstrap(bootstrap_request(), dependencies)
        local initial_request = registration('D:\\Clients\\Alpha\\.\\')
        local first = service.register_project(initial_request, dependencies)
        initial_request.normalized_configuration.filters[1] = 'changed'

        current_time = 200
        local refreshed = service.register_project(registration(
            'd:/clients/ALPHA', {
                display_name='Refreshed Alpha',
                normalized_configuration={filters={'refreshed'}},
                result_path='D:/Clients/Alpha/results/latest.json',
                project_id=first.project_id,
            }), dependencies)

        assert.equals(first.project_id, refreshed.project_id)
        assert.equals('D:/Clients/Alpha', refreshed.normalized_project_root)
        assert.equals('Refreshed Alpha', refreshed.display_name)
        assert.same({filters={'refreshed'}},
            refreshed.normalized_configuration)
        assert.equals('D:/Clients/Alpha/results/latest.json',
            refreshed.result_path)
        assert.equals(100, refreshed.registered_at)
        assert.equals(200, refreshed.refreshed_at)
        assert.equals(1, #service.projects(dependencies))
    end)

    it('keeps different roots, configurations, and result policies isolated',
            function()
        service.bootstrap(bootstrap_request(), dependencies)
        local alpha = service.register_project(
            registration('D:/Clients/Alpha'), dependencies)
        current_time = 200
        local beta_request = registration(
            'D:/Clients/Project With Spaces', {
                display_name='Beta',
                normalized_configuration={filters={'slow'}},
                result_policy='none',
            })
        beta_request.result_path = nil
        local beta = service.register_project(beta_request, dependencies)
        local listed = service.projects(dependencies)

        assert.is_not.equals(alpha.project_id, beta.project_id)
        assert.is_not.equals(alpha.normalized_project_root,
            beta.normalized_project_root)
        assert.equals('file', alpha.result_policy)
        assert.equals('none', beta.result_policy)
        assert.is_nil(beta.result_path)
        assert.same({'fast'}, alpha.normalized_configuration.filters)
        assert.same({'slow'}, beta.normalized_configuration.filters)
        assert.same({alpha.project_id, beta.project_id},
            {listed[1].project_id, listed[2].project_id})
    end)

    it('rejects project id reuse for another root without mutation', function()
        service.bootstrap(bootstrap_request(), dependencies)
        local alpha = service.register_project(
            registration('D:/Clients/Alpha'), dependencies)
        local before_registry = namespace.dwarfspec
        local before_projects = before_registry.projects
        local before_sequence = before_registry.next_project_sequence

        assert.has_error(function()
            service.register_project(registration('D:/Clients/Beta', {
                project_id=alpha.project_id,
            }), dependencies)
        end, 'project id project-1 belongs to a different normalized root')

        assert.equals(before_registry, namespace.dwarfspec)
        assert.equals(before_projects, namespace.dwarfspec.projects)
        assert.equals(before_sequence,
            namespace.dwarfspec.next_project_sequence)
        assert.equals('D:/Clients/Alpha',
            service.project(alpha.project_id, dependencies)
                .normalized_project_root)
    end)

    it('rejects incompatible and unsafe registrations atomically', function()
        service.bootstrap(bootstrap_request(), dependencies)
        local registry = namespace.dwarfspec
        local projects_before = registry.projects
        local sequence_before = registry.next_project_sequence
        local cyclic_configuration = {}
        cyclic_configuration.self = cyclic_configuration

        assert.has_error(function()
            service.register_project(registration('D:/Clients/Alpha', {
                client_compatibility={
                    protocol=1,
                    package_version='0.1.3',
                },
            }), dependencies)
        end, 'incompatible project protocol: expected 2, found 1')
        assert.has_error(function()
            service.register_project(registration('D:/Clients/Alpha', {
                client_compatibility={
                    protocol=2,
                    package_version='9.9.9',
                },
            }), dependencies)
        end, 'incompatible project package version: expected 0.1.3, ' ..
            'found 9.9.9')
        assert.has_error(function()
            service.register_project(registration('D:/Clients/Alpha', {
                normalized_configuration={callback=function() end},
            }), dependencies)
        end, 'JSON-safe value normalized project configuration.callback ' ..
            'has unsupported type function')
        assert.has_error(function()
            service.register_project(registration('D:/Clients/Alpha', {
                normalized_configuration=cyclic_configuration,
            }), dependencies)
        end, 'JSON-safe value contains a cycle at ' ..
            'normalized project configuration.self')

        assert.equals(projects_before, registry.projects)
        assert.equals(sequence_before, registry.next_project_sequence)
        assert.equals(0, #service.projects(dependencies))
    end)

    it('preserves compatible state across service module reloads', function()
        service.bootstrap(bootstrap_request(), dependencies)
        local project = service.register_project(
            registration('D:/Clients/Alpha'), dependencies)
        local registry = namespace.dwarfspec
        registry.runs['run-1']={run_id='run-1'}
        registry.queue[1]='run-1'
        registry.active_run_id='run-1'
        registry.latest_terminal_results[project.project_id]={
            run_id='older-run',
        }
        registry.quarantine={active=true, reason='fixture quarantine'}

        local reloaded = assert(loadfile(service_path))()
        local summary = reloaded.bootstrap(bootstrap_request(
            'D:/Packages/Other'), dependencies)

        assert.equals(registry, namespace.dwarfspec)
        assert.equals('D:/Packages/DwarfSpec', summary.package_root)
        assert.same({'run-1'}, summary.queue)
        assert.equals('run-1', summary.active_run_id)
        assert.is_true(summary.quarantine.active)
        assert.equals('older-run',
            summary.latest_terminal_results[project.project_id].run_id)
        assert.equals(project.project_id,
            reloaded.projects(dependencies)[1].project_id)
    end)

    it('rejects incompatible bootstrap without changing retained state',
            function()
        service.bootstrap(bootstrap_request(), dependencies)
        local project = service.register_project(
            registration('D:/Clients/Alpha'), dependencies)
        local registry = namespace.dwarfspec
        local projects_before = registry.projects
        registry.runs['run-1']={run_id='run-1'}
        registry.queue[1]='run-1'
        registry.active_run_id='run-1'
        registry.quarantine={active=true, reason='retained'}
        registry.latest_terminal_results[project.project_id]={
            run_id='terminal-1',
        }
        local runs_before = registry.runs
        local queue_before = registry.queue
        local quarantine_before = registry.quarantine
        local terminals_before = registry.latest_terminal_results

        assert.has_error(function()
            service.bootstrap(bootstrap_request(nil, '9.9.9'), dependencies)
        end, 'incompatible automation package version: expected 0.1.3, ' ..
            'found 9.9.9')
        assert.has_error(function()
            service.bootstrap({
                protocol_version=1,
                package_root='D:/Packages/DwarfSpec',
                package_version='0.1.3',
            }, dependencies)
        end, 'incompatible automation service protocol: expected 2, found 1')

        assert.equals(registry, namespace.dwarfspec)
        assert.equals(projects_before, registry.projects)
        assert.equals(runs_before, registry.runs)
        assert.equals(queue_before, registry.queue)
        assert.equals('run-1', registry.active_run_id)
        assert.equals(quarantine_before, registry.quarantine)
        assert.equals(terminals_before, registry.latest_terminal_results)
        assert.equals(project.project_id,
            service.projects(dependencies)[1].project_id)

        local legacy = {dwarfspec={
            protocol_version=1,
            generation=4,
            active_run={run_id='legacy'},
        }}
        local legacy_dependencies = {
            namespace=legacy,
            filesystem=dependencies.filesystem,
        }
        assert.has_error(function()
            service.bootstrap(bootstrap_request(), legacy_dependencies)
        end, 'runtime contains an incompatible automation registry')
        assert.equals(1, legacy.dwarfspec.protocol_version)
        assert.equals('legacy', legacy.dwarfspec.active_run.run_id)
    end)

    it('unregisters only idle projects', function()
        service.bootstrap(bootstrap_request(), dependencies)
        local project = service.register_project(
            registration('D:/Clients/Alpha'), dependencies)
        namespace.dwarfspec.projects[project.project_id]
            .outstanding_run_id = 'run-1'

        assert.has_error(function()
            service.unregister_project(project.project_id, dependencies)
        end, 'project project-1 still owns outstanding run run-1')
        assert.is_table(service.project(project.project_id, dependencies))

        namespace.dwarfspec.projects[project.project_id]
            .outstanding_run_id = nil
        local removed = service.unregister_project(
            project.project_id, dependencies)
        assert.equals(project.project_id, removed.project_id)
        assert.is_nil(service.project(project.project_id, dependencies))
        assert.equals(0, #service.projects(dependencies))
    end)

    it('returns detached JSON-safe project and service summaries', function()
        local json = require('dkjson')
        service.bootstrap(bootstrap_request(), dependencies)
        local project = service.register_project(
            registration('D:/Clients/Alpha'), dependencies)
        local registry = namespace.dwarfspec
        registry.queue[1]='run-1'
        registry.quarantine={active=true, reason='fixture'}
        registry.latest_terminal_results[project.project_id]={
            run_id='terminal-1',
        }

        local project_summary = service.project(
            project.project_id, dependencies)
        local service_summary = service.summary(dependencies)
        project_summary.normalized_configuration.filters[1] = 'mutated'
        service_summary.queue[1] = 'mutated'
        service_summary.quarantine.reason = 'mutated'
        service_summary.latest_terminal_results[project.project_id]
            .run_id = 'mutated'

        local fresh_project = service.project(project.project_id, dependencies)
        local fresh_service = service.summary(dependencies)
        assert.same({'fast'},
            fresh_project.normalized_configuration.filters)
        assert.same({'run-1'}, fresh_service.queue)
        assert.equals('fixture', fresh_service.quarantine.reason)
        assert.equals('terminal-1',
            fresh_service.latest_terminal_results[project.project_id].run_id)
        assert.is_nil(fresh_project.normalized_identity)
        assert.is_string(json.encode(fresh_project))
        assert.is_string(json.encode(fresh_service))
    end)

    it('keeps internal project operations copy-on-write', function()
        local original = {}
        local next_id_called = false
        local updated, project = projects.register(original,
            registration('D:/Clients/Alpha'), {
                filesystem=dependencies.filesystem,
                now_ms=function()
                    return 100
                end,
                next_project_id=function()
                    next_id_called = true
                    return 'project-copy'
                end,
            })

        assert.is_true(next_id_called)
        assert.is_nil(original['project-copy'])
        assert.is_table(updated['project-copy'])
        assert.equals('project-copy', project.project_id)
    end)

    it('exposes immutable event, run, and scheduler observations',
            function()
        service.bootstrap(bootstrap_request(), dependencies)
        local project = service.register_project(
            registration('D:/Clients/Alpha'), dependencies)
        local registry = namespace.dwarfspec
        local journal = events.new_journal({
            service_instance_id=registry.service_instance_id,
            project_id=project.project_id,
            run_id='run-1',
            generation=1,
            admitted_at_ms=100,
        })
        events.publish(journal, EventType.RUN_QUEUED, {
            selection={identities={'tests/live/example.ds.lua'}},
            queue_admitted_ms=100,
            owner_kind='external',
        }, 100)
        registry.runs['run-1']={
            service_instance_id=registry.service_instance_id,
            project_id=project.project_id,
            run_id='run-1',
            generation=1,
            state='queued',
            terminal=false,
            submitted_at_ms=100,
            counts={successes=0, failures=0, errors=0, pending=0},
            totals={successes=0, failures=0, errors=0, pending=0},
            queue_lease={active=true},
            execution_lease={active=false},
            owner_kind='external',
            cleanup_confirmed=false,
            mount_cleanup_verified=false,
            failures={},
            event_journal=journal,
        }
        registry.queue[1]='run-1'

        local run_snapshot = service.snapshot('run-1', dependencies)
        local cursor = service.events('run-1', 0, dependencies)
        local scheduler = service.scheduler_snapshot(dependencies)
        run_snapshot.counts.successes = 99
        cursor.events[1].payload.owner_kind = 'mutated'
        scheduler.queue[1].run_id = 'mutated'

        assert.equals(0, registry.runs['run-1'].counts.successes)
        assert.equals('external',
            journal.events[1].payload.owner_kind)
        assert.equals('run-1', registry.queue[1])
        assert.equals(1, cursor.last_sequence)
        assert.equals(1, run_snapshot.queue_position)
    end)
end)
