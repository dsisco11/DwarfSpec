-- Unit contracts for owner-scoped cleanup result materialization.

local EventType = require('dwarfspec.protocol.enums.event_types')
local events = require('dwarfspec.protocol.events')
local materializer = require(
    'dwarfspec.host.execution.cleanup_result_materializer')
local Revision = require('dwarfspec.protocol.verified_execution_revision')

---Creates one valid cleanup lifecycle payload.
---@param event_type string
---@param state string
---@return table
local function cleanup_event(event_type, state)
    local event = {schema=Revision.EVENT_SCHEMA,
        protocol_version=Revision.PROTOCOL_VERSION, event_type=event_type,
        transaction_id='run-1:cleanup:1', registration_ordinal=1,
        label='restore fixture', lifetime='owner', owner_scope='test_attempt',
        service_run_id='run-1', suite_execution_id='suite-1',
        test_attempt_id='attempt-1', repeat_index=1,
        spec_file_identity='tests/example_spec.lua', test_identity='example',
        state=state, registered_at_ms=10}
    if event_type == 'cleanup.transaction_started' then
        event.trigger = 'owner_teardown'
        event.execution_started_at_ms = 11
    elseif event_type == 'cleanup.transaction_finished' then
        event.trigger = 'owner_teardown'
        event.execution_started_at_ms = 11
        event.completed_at_ms = 12
        event.disposition = 'complete'
        event.restore_outcome = 'complete'
        event.verification_outcome = 'complete'
        event.evidence = {restore_succeeded=true, verification_succeeded=true}
    end
    return event
end

describe('CleanupResultMaterializer', function()
    it('folds one owner journal into ordinal terminal results', function()
        local journal = events.new_journal({service_instance_id='service-1',
            project_id='project-1', run_id='run-1', generation=1,
            admitted_at_ms=0})
        events.publish(journal, EventType.CLEANUP_TRANSACTION_REGISTERED,
            {cleanup_event=cleanup_event('cleanup.transaction_registered',
                'pending')}, 10)
        events.publish(journal, EventType.CLEANUP_TRANSACTION_STARTED,
            {cleanup_event=cleanup_event('cleanup.transaction_started',
                'running')}, 11)
        events.publish(journal, EventType.CLEANUP_TRANSACTION_FINISHED,
            {cleanup_event=cleanup_event('cleanup.transaction_finished',
                'complete')}, 12)
        local results = materializer.fold_owner(journal.events, {
            owner_scope='test_attempt', service_run_id='run-1',
            suite_execution_id='suite-1', test_attempt_id='attempt-1'})
        assert.same({{
            transaction_id='run-1:cleanup:1', registration_ordinal=1,
            label='restore fixture', lifetime='owner', owner_scope='test_attempt',
            service_run_id='run-1', suite_execution_id='suite-1',
            test_attempt_id='attempt-1', registered_at_ms=10,
            execution_started_at_ms=11, completed_at_ms=12,
            disposition='complete', restore_outcome='complete',
            verification_outcome='complete',
            evidence={restore_succeeded=true, verification_succeeded=true},
        }}, results)
        local schemas = require(
            'dwarfspec.protocol.verified_execution_schemas').new()
        local report = {schema=Revision.RESULT_SCHEMA, protocol_version=3,
            service_run_id='run-1', service_cleanup_transactions={},
            suite_executions={}, test_attempts={{service_run_id='run-1',
                suite_execution_id='suite-1', test_attempt_id='attempt-1',
                test_identity='example', repeat_index=1,
                cleanup_transactions=results}}}
        assert.same(report, schemas:validate_cleanup_projections(report,
            journal.events))
        report.test_attempts[1].cleanup_transactions[1].disposition = 'failed'
        assert.has_error(function()
            schemas:validate_cleanup_projections(report, journal.events)
        end, 'cleanup result projection does not equal its journal fold')
    end)
end)
