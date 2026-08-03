-- Unit contract for canonical adapter-error construction and serialization.

local adapter_errors = require('dwarfspec.protocol.adapter_errors')
local reports = require('dwarfspec.controller.reporting.report')
local RunnerFailureKind =
    require('dwarfspec.protocol.enums.runner_failure_kinds')
local SchedulerFailureKind =
    require('dwarfspec.protocol.enums.scheduler_failure_kinds')

---Encodes one value through the controller test JSON implementation.
---@param value table
---@return string
local function encode(value)
    return require('dkjson').encode(value)
end

---Returns one valid package-version domain rejection.
---@return table
local function mismatch()
    return adapter_errors.domain('package_version_mismatch',
        'different version loaded', {
            running_version='0.2.1',
            requested_version='0.2.2',
        })
end

describe('adapter error protocol', function()
    it('round trips construction, serialization, and controller validation',
            function()
        local json, emitted = adapter_errors.serialize(mismatch(),
            RunnerFailureKind.REGISTRATION, encode)
        local transport, payload, rejection = reports.parse_transport_response({
            'DWARFSPEC_JSON ' .. json,
        }, {})
        assert.is_nil(transport)
        assert.equals(json, payload)
        assert.same(emitted, rejection)
        assert.same({
            schema='dwarfspec.error.v1',
            protocol=2,
            kind='registration',
            code='package_version_mismatch',
            message='different version loaded',
            running_version='0.2.1',
            requested_version='0.2.2',
        }, rejection)
    end)

    it('requires every exact known-code field', function()
        for _, fields in ipairs({
            {requested_version='0.2.2'},
            {running_version='0.2.1'},
            {running_version='', requested_version='0.2.2'},
            {running_version='0.2.1', requested_version=2},
            {running_version='0.2.1', requested_version='0.2.2', extra=true},
        }) do
            assert.has_error(function()
                adapter_errors.domain('package_version_mismatch', 'message', fields)
            end)
        end
    end)

    it('validates every admission conflict with only safe blocking context',
            function()
        for _, code in ipairs({
            SchedulerFailureKind.PROJECT_BUSY,
            SchedulerFailureKind.REQUEST_KEY_CONFLICT,
            SchedulerFailureKind.RESULT_PATH_BUSY,
        }) do
            local rejection = adapter_errors.domain(code, 'admission conflict', {
                blocking_run_id='blocking-run',
                blocking_generation=7,
                state='queued',
                reason='scheduler classification detail',
            })
            local envelope = adapter_errors.envelope(rejection,
                RunnerFailureKind.REGISTRATION)
            assert.equals(RunnerFailureKind.REGISTRATION, envelope.kind)
            assert.equals(code, envelope.code)
            assert.equals('blocking-run', envelope.blocking_run_id)
            assert.equals(7, envelope.blocking_generation)
            assert.equals('queued', envelope.state)
            assert.is_nil(envelope.project_root)
            assert.is_nil(envelope.result_path)

            for _, missing in ipairs({
                'blocking_run_id', 'blocking_generation', 'state', 'reason',
            }) do
                local fields = {
                    blocking_run_id='blocking-run',
                    blocking_generation=7,
                    state='queued',
                    reason='scheduler classification detail',
                }
                fields[missing] = nil
                assert.has_error(function()
                    adapter_errors.domain(code, 'admission conflict', fields)
                end)
            end
        end
    end)

    it('validates every mutation rejection subtype and safe required fields',
            function()
        local cases = {
            service_not_loaded={operation='abort'},
            run_not_found={operation='cancel', run_id='run-1'},
            generation_mismatch={operation='acknowledgement', run_id='run-1',
                generation=2, current_generation=3},
            invalid_run_state={operation='discard', run_id='run-1',
                generation=3, state='running'},
            owner_capability_rejected={operation='recover', run_id='run-1',
                generation=3, state='running'},
            quarantine_mismatch={operation='recover executor', run_id='run-1',
                generation=3, blocking_run_id='run-2', blocking_generation=4},
            clean_state_unverified={operation='recover executor', run_id='run-1',
                generation=3, reason='cleanup remains active'},
            event_cursor_ahead={operation='status poll', run_id='run-1',
                generation=3, state='running', after_sequence=8,
                last_sequence=7},
        }
        for code, fields in pairs(cases) do
            local rejection = adapter_errors.domain(code, 'rejected', fields)
            local envelope = adapter_errors.envelope(rejection,
                RunnerFailureKind.HOST)
            assert.equals(RunnerFailureKind.HOST, envelope.kind)
            assert.equals(code, envelope.code)
            assert.is_nil(envelope.owner_capability)
            assert.is_nil(envelope.authorization_proof)
            for name in pairs(fields) do
                local incomplete = {}
                for field, value in pairs(fields) do incomplete[field] = value end
                incomplete[name] = nil
                assert.has_error(function()
                    adapter_errors.domain(code, 'rejected', incomplete)
                end)
            end
        end
    end)

    it('rejects non-JSON-safe and forbidden domain fields', function()
        for _, fields in ipairs({
            {operation=function() end},
            {owner_capability='secret'},
            {authorization_proof='secret'},
            {package_root='C:/private'},
            {project_root='C:/private'},
            {result_path='C:/private/result.json'},
        }) do
            assert.has_error(function()
                adapter_errors.domain('future_code', 'message', fields)
            end)
        end
    end)

    it('requires an event cursor rejection to describe an ahead cursor',
            function()
        for _, after_sequence in ipairs({6, 7}) do
            assert.has_error(function()
                adapter_errors.domain('event_cursor_ahead', 'stale cursor', {
                    operation='status poll', run_id='run-1', generation=3,
                    state='running', after_sequence=after_sequence,
                    last_sequence=7,
                })
            end)
        end
    end)

    it('retains generic and unknown compatibility without known fields', function()
        local generic = adapter_errors.envelope('generic rejection',
            RunnerFailureKind.REGISTRATION)
        assert.is_nil(generic.code)
        assert.equals('generic rejection', generic.message)

        local unknown = adapter_errors.envelope(adapter_errors.domain(
            'future_code', 'future rejection', {
                operation='cancel', run_id='run-1', generation=2,
                state='queued', blocking_run_id='run-0',
                blocking_generation=1,
            }), RunnerFailureKind.HOST)
        assert.equals('future_code', unknown.code)
        assert.equals('host', unknown.kind)
        assert.equals('cancel', unknown.operation)
    end)

    it('preserves the executor quarantine compatibility fixture', function()
        local response = adapter_errors.executor_quarantine({
            blocking_run_id='run-1',
            blocking_generation=3,
            reason='cleanup was not confirmed',
        })
        assert.equals('executor_quarantined', response.kind)
        assert.is_nil(response.code)
        assert.matches('recover-executor run-1 --generation 3', response.message,
            1, true)
    end)

    it('uses an uncoded bounded host fallback when serialization fails',
            function()
        local unprintable = setmetatable({}, {
            __tostring=function() error('cannot render') end,
        })
        local json, response = adapter_errors.serialize(unprintable,
            RunnerFailureKind.REGISTRATION, function() error('encode failure') end)
        assert.matches('"kind":"host"', json, 1, true)
        assert.is_nil(response.code)
        assert.is_true(#response.message <= 512)
    end)
end)
