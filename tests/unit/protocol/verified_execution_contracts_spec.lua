-- Unit contracts for verified-execution vocabulary and successor schemas.

local CleanupOwnerScope = require(
    'dwarfspec.protocol.enums.cleanup_owner_scopes')
local CleanupState = require('dwarfspec.protocol.enums.cleanup_states')
local CleanupTrigger = require(
    'dwarfspec.protocol.enums.cleanup_execution_triggers')
local CommandKind = require('dwarfspec.protocol.enums.command_kinds')
local Revision = require('dwarfspec.protocol.verified_execution_revision')
local Schemas = require('dwarfspec.protocol.verified_execution_schemas')

---Returns one valid terminal cleanup projection.
---@param scope string
---@param id string
---@return table
local function cleanup_result(scope, id)
    local value = {
        transaction_id=id,
        registration_ordinal=1,
        label='restore fixture',
        lifetime='owner',
        owner_scope=scope,
        service_run_id='service-1',
        disposition='complete',
        registered_at_ms=10,
        completed_at_ms=20,
        restore_outcome='complete',
        verification_outcome='complete',
    }
    if scope ~= CleanupOwnerScope.SERVICE_RUN then
        value.suite_execution_id = 'suite-1'
    end
    if scope == CleanupOwnerScope.TEST_ATTEMPT then
        value.test_attempt_id = 'attempt-1'
    end
    return value
end

describe('verified execution contracts', function()
    it('publishes every closed immutable vocabulary', function()
        local contracts = {
            {CommandKind, {'action', 'assertion', 'fixture', 'query',
                'state_setter', 'workflow'}},
            {require('dwarfspec.protocol.enums.intrinsic_verification_kinds'),
                {'callback', 'execution_receipt', 'primary_observation'}},
            {require('dwarfspec.protocol.enums.execution_retry_policies'),
                {'explicit_retry_safe', 'once'}},
            {require('dwarfspec.protocol.enums.execution_owner_scopes'),
                {'service_run', 'suite_execution', 'test_attempt'}},
            {CleanupOwnerScope,
                {'service_run', 'suite_execution', 'test_attempt'}},
            {require('dwarfspec.protocol.enums.cleanup_lifetimes'),
                {'command', 'owner'}},
            {CleanupState,
                {'abandoned', 'complete', 'failed', 'pending', 'running',
                    'unconfirmed'}},
            {require('dwarfspec.protocol.enums.cleanup_terminal_dispositions'),
                {'abandoned', 'complete', 'failed', 'unconfirmed'}},
            {CleanupTrigger,
                {'command_finally', 'manual', 'owner_teardown'}},
            {require('dwarfspec.protocol.enums.command_failure_stages'),
                {'caller_verification', 'claim_planning', 'cleanup_registration',
                    'command_cleanup', 'execution', 'intrinsic_verification',
                    'normalization', 'preflight', 'result_projection'}},
        }
        for _, contract in ipairs(contracts) do
            local values = {}
            for _, value in pairs(contract[1]) do values[#values + 1] = value end
            table.sort(values)
            assert.same(contract[2], values)
            assert.has_error(function() contract[1].EXTRA = 'extra' end)
        end
    end)

    it('rejects every mixed successor protocol combination', function()
        assert.equals(3, Revision.negotiate(3, 3, 3, 3))
        for mask = 1, 14 do
            local versions = {}
            for position = 1, 4 do
                versions[position] = mask & (1 << (position - 1)) == 0 and
                    2 or 3
            end
            assert.has_error(function()
                Revision.negotiate(table.unpack(versions))
            end)
        end
    end)

    it('validates command ancestry and lifecycle event shapes', function()
        local schemas = Schemas.new()
        schemas:validate_command_identity({
            invocation_id='child', root_invocation_id='root',
            parent_invocation_id='root', owner_scope='test_attempt',
            service_run_id='service-1', suite_execution_id='suite-1',
            test_attempt_id='attempt-1',
        })
        assert.has_error(function()
            schemas:validate_command_identity({
                invocation_id='child', root_invocation_id='root',
                parent_invocation_id='root',
                parent_cleanup_transaction_id='cleanup-1',
                owner_scope='service_run', service_run_id='service-1',
            })
        end)
        schemas:validate_cleanup_event({
            schema=Revision.EVENT_SCHEMA, protocol_version=3,
            event_type='cleanup.transaction_started',
            transaction_id='cleanup-1', owner_scope='service_run',
            service_run_id='service-1', state=CleanupState.RUNNING,
            trigger=CleanupTrigger.MANUAL, registration_ordinal=1,
            label='restore fixture', lifetime='owner', registered_at_ms=10,
            execution_started_at_ms=11,
        })
    end)

    it('requires all three unique ownership-consistent projections', function()
        local schemas = Schemas.new()
        local report = {
            schema=Revision.RESULT_SCHEMA, protocol_version=3,
            service_run_id='service-1',
            service_cleanup_transactions={
                cleanup_result(CleanupOwnerScope.SERVICE_RUN, 'cleanup-1'),
            },
            suite_executions={{
                service_run_id='service-1', suite_execution_id='suite-1',
                repeat_index=1, spec_file_identity='suite/example.ds.lua',
                behavior_summary={}, cleanup_outcome='complete',
                cleanup_transactions={
                    cleanup_result(CleanupOwnerScope.SUITE_EXECUTION,
                        'cleanup-2'),
                },
            }},
            test_attempts={{
                service_run_id='service-1', suite_execution_id='suite-1',
                test_attempt_id='attempt-1', test_identity='suite test',
                repeat_index=1,
                cleanup_transactions={
                    cleanup_result(CleanupOwnerScope.TEST_ATTEMPT,
                        'cleanup-3'),
                },
            }},
        }
        assert.equals(report, schemas:validate_host_report(report))
        report.test_attempts[1].cleanup_transactions[1].transaction_id =
            'cleanup-2'
        assert.has_error(function() schemas:validate_host_report(report) end)
    end)
end)
