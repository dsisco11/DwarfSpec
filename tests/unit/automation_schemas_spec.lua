-- Unit contracts for versioned automation schemas and immutable snapshots.

local events = require('dwarfspec.automation.events')
local EventType = require('dwarfspec.automation.event_types')
local ResultPolicy = require('dwarfspec.automation.result_policies')
local ResultState = require('dwarfspec.automation.result_states')
local RunState = require('dwarfspec.automation.run_states')
local schemas = require('dwarfspec.automation.schemas')
local snapshots = require('dwarfspec.automation.snapshots')

---Returns one valid internal run record.
---@param state DwarfSpecRunState|nil
---@param terminal boolean|nil
---@return table
local function run_record(state, terminal)
    return {
        service_instance_id='service-schema-1',
        project_id='project-schema-1',
        run_id='run-schema-1',
        generation=3,
        state=state or RunState.QUEUED,
        terminal=terminal == true,
        submitted_at_ms=100,
        counts={successes=0, failures=0, errors=0, pending=0},
        totals={successes=0, failures=0, errors=0, pending=0},
        queue_lease={active=true, expires_at_ms=1100},
        execution_lease={active=false},
        owner_kind='external',
        cleanup_confirmed=false,
        mount_cleanup_verified=false,
        failures={},
        event_journal=events.new_journal({
            service_instance_id='service-schema-1',
            project_id='project-schema-1',
            run_id='run-schema-1',
            generation=3,
            admitted_at_ms=100,
        }),
    }
end

---Returns one valid internal service registry.
---@param run table
---@return table
local function registry(run)
    return {
        schema='dwarfspec.service.v2',
        protocol_version=2,
        service_instance_id='service-schema-1',
        package_root='D:/Packages/DwarfSpec',
        package_version='0.2.0',
        generation=3,
        next_project_sequence=2,
        projects={
            ['project-schema-1']={
                project_id='project-schema-1',
                normalized_project_root='D:/Clients/Schema',
                normalized_identity='d:/clients/schema',
                display_name='Schema Project',
                normalized_configuration={filters={}},
                result_path='D:/Clients/Schema/tests/.test-results/' ..
                    'dwarfspec/results.json',
            result_policy=ResultPolicy.FILE,
                client_compatibility={
                    protocol=2,
                    package_version='0.2.0',
                },
                registered_at=50,
                refreshed_at=50,
                outstanding_run_id=run.run_id,
            },
        },
        runs={[run.run_id]=run},
        queue={run.run_id},
        active_run_id=nil,
        quarantine={active=false},
        latest_terminal_results={},
    }
end

describe('automation version 2 schemas and snapshots', function()
    it('builds immutable run snapshots with required operational state',
            function()
        local run = run_record()
        local service = registry(run)
        local snapshot = snapshots.run(run, service)

        assert.equals('dwarfspec.run.v2', snapshot.schema)
        assert.equals(1, snapshot.queue_position)
        assert.equals(0, snapshot.last_sequence)
        assert.is_true(snapshot.queue_lease.active)
        assert.is_false(snapshot.execution_lease.active)
        assert.is_false(snapshot.cleanup_confirmed)
        assert.is_false(snapshot.mount_cleanup_verified)

        snapshot.counts.successes = 10
        snapshot.queue_lease.active = false
        assert.equals(0, run.counts.successes)
        assert.is_true(run.queue_lease.active)

        run.state = RunState.RUNNING
        run.activated_at_ms = 150
        run.queue_wait_ms = 50
        run.current_repeat = 1
        run.current_test = 'suite test'
        run.execution_lease = {active=true, expires_at_ms=1150}
        run.cleanup_reason = 'completion pending'
        run.host_error = {kind='host', message='fixture host error'}
        run.failures = {{
            kind='failure',
            name='suite test',
            message='expected true',
        }}
        service.queue = {}
        service.active_run_id = run.run_id
        local running = snapshots.run(run, service)

        assert.is_nil(running.queue_position)
        assert.equals(150, running.activated_at_ms)
        assert.equals(50, running.queue_wait_ms)
        assert.equals(1, running.current_repeat)
        assert.equals('suite test', running.current_test)
        assert.is_true(running.execution_lease.active)
        assert.equals('completion pending', running.cleanup_reason)
        assert.equals('fixture host error', running.host_error.message)
        assert.equals('expected true', running.failures[1].message)
    end)

    it('validates every terminal run state and rejects flag mismatches',
            function()
        for _, state in ipairs({
                RunState.PASSED,
                RunState.FAILED,
                RunState.ABORTED,
                RunState.CANCELLED}) do
            local run = run_record(state, true)
            run.cleanup_confirmed = true
            run.mount_cleanup_verified = true
            local snapshot = snapshots.run(run, registry(run))
            assert.equals(state,
                schemas.validate_run(snapshot).state)
        end

        local invalid = snapshots.run(run_record(), registry(run_record()))
        invalid.terminal = true
        assert.has_error(function()
            schemas.validate_run(invalid)
        end, 'automation run terminal flag does not match state')
    end)

    it('builds immutable scheduler snapshots with FIFO ownership',
            function()
        local run = run_record()
        local service = registry(run)
        local snapshot = snapshots.scheduler(service)

        assert.equals('dwarfspec.scheduler.v2', snapshot.schema)
        assert.same({
            {run_id='run-schema-1', project_id='project-schema-1'},
        }, snapshot.queue)
        assert.equals(1, #snapshot.projects)
        assert.is_nil(snapshot.active_run_id)
        snapshot.queue[1].run_id = 'mutated'
        snapshot.projects[1].display_name = 'mutated'
        snapshot.quarantine.active = true

        assert.equals('run-schema-1', service.queue[1])
        assert.equals('Schema Project',
            service.projects['project-schema-1'].display_name)
        assert.is_false(service.quarantine.active)

        service.queue = {}
        service.active_run_id = run.run_id
        run.state = RunState.RUNNING
        local active = snapshots.scheduler(service)
        assert.equals('run-schema-1', active.active_run_id)
        assert.equals('project-schema-1', active.active_project_id)
        assert.same({}, active.queue)
    end)

    it('builds and validates immutable retained-run history', function()
        local run = run_record()
        run.output_lines = {'START example', 'SUCCESS example'}
        local service = registry(run)
        local older = run_record(RunState.PASSED, true)
        older.run_id = 'run-schema-older'
        older.generation = 2
        older.cleanup_confirmed = true
        older.mount_cleanup_verified = true
        older.output_lines = {'SUCCESS older'}
        service.runs[older.run_id] = older

        local history = {
            schema='dwarfspec.history.v1',
            protocol=2,
            service_loaded=true,
            service_instance_id=service.service_instance_id,
            runs=snapshots.history(service),
        }

        assert.equals(history, schemas.validate_run_history(history))
        assert.equals('run-schema-1', history.runs[1].run_id)
        assert.equals(2, history.runs[1].log_line_count)
        assert.equals('run-schema-older', history.runs[2].run_id)
        history.runs[1].state = RunState.PASSED
        assert.equals(RunState.QUEUED, run.state)
    end)

    it('validates retained-run inspection and log envelopes', function()
        local run = run_record()
        local service = registry(run)
        local snapshot = snapshots.run(run, service)
        local inspection = {
            schema='dwarfspec.run-inspection.v1',
            protocol=2,
            service_loaded=true,
            found=true,
            run_id=run.run_id,
            snapshot=snapshot,
            events={},
            last_sequence=0,
            project_name='Schema Project',
            project_root='D:/Clients/Schema',
        }
        local logs = {
            schema='dwarfspec.run-logs.v1',
            protocol=2,
            service_loaded=true,
            found=true,
            service_instance_id=run.service_instance_id,
            project_id=run.project_id,
            run_id=run.run_id,
            generation=run.generation,
            state=run.state,
            lines={'START example', 'SUCCESS example'},
        }

        assert.same(inspection,
            schemas.validate_run_inspection(inspection))
        assert.same(logs, schemas.validate_run_logs(logs))
        assert.same({
            schema='dwarfspec.run-inspection.v1',
            protocol=2,
            service_loaded=false,
            found=false,
            run_id='missing',
        }, schemas.validate_run_inspection({
            schema='dwarfspec.run-inspection.v1',
            protocol=2,
            service_loaded=false,
            found=false,
            run_id='missing',
        }))
    end)

    it('validates transport identity and contiguous cursor responses',
            function()
        local run = run_record(RunState.FAILED, true)
        run.cleanup_confirmed = true
        run.mount_cleanup_verified = true
        events.publish(run.event_journal, EventType.RUN_FINISHED, {
            terminal_state=RunState.FAILED,
            totals=run.totals,
            cleanup_required=true,
            cleanup_confirmed=true,
        }, 110)
        local snapshot = snapshots.run(run, registry(run))
        local response = {
            schema='dwarfspec.transport.v2',
            protocol=2,
            service_instance_id=run.service_instance_id,
            project_id=run.project_id,
            run_id=run.run_id,
            generation=run.generation,
            snapshot=snapshot,
            events=events.read(run.event_journal, 0).events,
            last_sequence=1,
        }

        assert.equals(response,
            schemas.validate_transport(response, {
                service_instance_id=run.service_instance_id,
                project_id=run.project_id,
                run_id=run.run_id,
                generation=run.generation,
                after_sequence=0,
            }))
        response.events[1].sequence = 2
        assert.has_error(function()
            schemas.validate_transport(response, {after_sequence=0})
        end, 'automation transport event sequence discontinuity: ' ..
            'expected 1, found 2')
    end)

    it('rejects capabilities and runtime objects from snapshots', function()
        local run = run_record()
        run.queue_lease.owner_capability = 'secret'
        assert.has_error(function()
            snapshots.run(run, registry(run))
        end, 'owner capability is forbidden at automation run.queue_lease')

        run.queue_lease.owner_capability = nil
        run.host_error = {screen=setmetatable({}, {__name='screen'})}
        assert.has_error(function()
            snapshots.run(run, registry(run))
        end, 'JSON-safe table must not have a behavioral metatable at ' ..
            'automation run.host_error.screen')

        assert.has_error(function()
            schemas.validate_result({
                schema='dwarfspec.result.v2',
            state=ResultState.PASSED,
                terminal=true,
                service_instance_id='service-schema-1',
                project_id='project-schema-1',
                run_id='run-schema-1',
                generation=3,
                exit_code=0,
                project_root='D:/Clients/Schema',
                selection={identities={}},
                events={},
                owner_capability='secret',
            })
        end, 'owner capability is forbidden at automation result')
    end)

    it('rejects malformed service, scheduler, and result schemas',
            function()
        assert.has_error(function()
            schemas.validate_service({
                schema='dwarfspec.service.v1',
            })
        end, 'unsupported automation service schema: dwarfspec.service.v1')
        assert.has_error(function()
            schemas.validate_scheduler({
                schema='dwarfspec.scheduler.v2',
                protocol_version=1,
            })
        end, 'unsupported automation scheduler protocol: 1')
        assert.has_error(function()
            schemas.validate_result({
                schema='dwarfspec.result.v2',
                state='invented',
                terminal=true,
            })
        end, 'automation result has unsupported state: invented')
    end)
end)
