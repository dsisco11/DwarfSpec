-- Direct contracts for cancellation, acknowledgement, and executor recovery.

local module = require('dwarfspec.controller.execution.run_recovery')
local RunState = require('dwarfspec.protocol.enums.run_states')

---Creates recovery operations and a record of every dependency call.
---@param behavior table|nil
---@return table, table
local function fixture(behavior)
    behavior = behavior or {}
    local record = {}
    local builder = {
        recover=function(_, run_id, owner, cursor)
            record.recover={run_id=run_id, owner=owner, cursor=cursor}
            return {'recover'}
        end,
        abort=function(_, run_id)
            record.abort={run_id=run_id}
            return {'abort'}
        end,
        acknowledge=function(_, run_id, generation, owner, cursor)
            record.acknowledge={run_id=run_id, generation=generation,
                owner=owner, cursor=cursor}
            return {'acknowledge'}
        end,
        recover_executor=function(_, run_id, generation, reason)
            record.recover_executor={run_id=run_id, generation=generation,
                reason=reason}
            return {'recover-executor'}
        end,
    }
    local client = {
        invoke=function(_, _, arguments)
            record.invoke=arguments
            return behavior.invoke or {exit_code=0, lines={'transport'}}
        end,
        parse_transport=function(_, expected)
            record.parse_expected=expected
            if behavior.parse_error then error(behavior.parse_error) end
            return behavior.recovery_transport
        end,
        transport=function(_, _, arguments, expected, operation)
            record.transport={arguments=arguments, expected=expected,
                operation=operation}
            if behavior.transport_error then error(behavior.transport_error) end
            return behavior.transport
        end,
    }
    local service = module.new({builder=builder, client=client,
        failure=function(kind, message)
            return {kind=kind, message=message, exit_code=5}
        end, failure_kinds={HOST='host', TEST='test', SUCCESS='success'},
        exit_codes={success=0, host=5, test=6}, clean_message=tostring})
    return service, record
end

describe('controller run recovery', function()
    it('selects queued cancellation or active recovery and forwards authority', function()
        local cancelled = {snapshot={state=RunState.CANCELLED,
            terminal=true, cleanup_confirmed=false}}
        local service, record = fixture({recovery_transport=cancelled})
        local recovered, detail = service.after_failure({}, 'runner', 'run',
            nil, nil, 4)
        assert.is_nil(detail)
        assert.same(cancelled, recovered)
        assert.same({run_id='run', cursor=4}, record.recover)
        assert.same({run_id='run', after_sequence=4}, record.parse_expected)

        local aborted = {snapshot={state=RunState.ABORTED,
            terminal=true, cleanup_confirmed=true}}
        service, record = fixture({recovery_transport=aborted})
        recovered, detail = service.after_failure({}, 'runner', 'run',
            'owner', {service_instance_id='service', run_id='run',
                generation=2}, 7)
        assert.is_nil(detail)
        assert.same(aborted, recovered)
        assert.same({run_id='run', owner='owner', cursor=7}, record.recover)
        assert.same({service_instance_id='service', run_id='run', generation=2,
            after_sequence=7}, record.parse_expected)
    end)

    it('requires cleanup for active recovery while allowing queued cancellation', function()
        local cases = {
            {state=RunState.CANCELLED, cleanup=false, expected=nil},
            {state=RunState.ABORTED, cleanup=true, expected=nil},
            {state=RunState.ABORTED, cleanup=false,
                expected='recovery abort did not confirm cleanup'},
            {state=RunState.PASSED, cleanup=false,
                expected='recovery terminal cleanup was not confirmed'},
        }
        for _, case in ipairs(cases) do
            local service = fixture({recovery_transport={snapshot={
                state=case.state, terminal=true,
                cleanup_confirmed=case.cleanup}}})
            local _, detail = service.after_failure({}, 'runner', 'run',
                'owner', {run_id='run'}, 0)
            assert.same(case.expected, detail)
        end
    end)

    it('preserves the original failure when recovery also fails', function()
        local service = fixture({invoke={exit_code=1, lines={}}})
        local _, detail = service.after_failure({}, 'runner', 'run',
            'owner', {run_id='run'}, 4)
        local original = {kind='timeout', message='original timeout'}
        assert.same(original, service.preserve_error(original, detail))
        assert.same('timeout', original.kind)
        assert.same('original timeout; recovery failed: recovery exited with 1',
            original.message)
    end)

    it('classifies queued and active explicit abort cleanup outcomes', function()
        local service = fixture({transport={snapshot={state=RunState.CANCELLED},
            events={'cancelled'}}})
        local outcome = service.abort({}, 'runner', 'run')
        assert.same(0, outcome.exit_code)
        assert.same({'cancelled'}, outcome.events)

        service = fixture({transport={snapshot={state=RunState.ABORTED,
            cleanup_confirmed=true}, events={'aborted'}}})
        outcome = service.abort({}, 'runner', 'run')
        assert.same(0, outcome.exit_code)
        service = fixture({transport={snapshot={state=RunState.ABORTED,
            cleanup_confirmed=false}, events={}}})
        outcome = service.abort({}, 'runner', 'run')
        assert.same(6, outcome.exit_code)
        assert.matches('did not confirm cleanup', outcome.error.message)
    end)

    it('forwards acknowledgement identity and surfaces acknowledgement failure', function()
        local service, record = fixture({transport={snapshot={}}})
        service.acknowledge({}, 'runner', 'run', 2, 'owner',
            {service_instance_id='service', run_id='run', generation=2}, 4)
        assert.same({run_id='run', generation=2, owner='owner', cursor=4},
            record.acknowledge)
        assert.same({service_instance_id='service', run_id='run', generation=2,
            after_sequence=4}, record.transport.expected)
        assert.same('acknowledgement', record.transport.operation)

        service = fixture({transport_error='acknowledgement failed'})
        assert.has_error(function()
            service.acknowledge({}, 'runner', 'run', 2, 'owner',
                {run_id='run'}, 4)
        end)
    end)

    it('requires exact executor recovery to clear quarantine', function()
        local service, record = fixture({transport={snapshot={},
            scheduler={quarantine={active=true}}}})
        local outcome = service.recover_executor({}, 'runner', 'run', 2, 'reason')
        assert.same(5, outcome.exit_code)
        assert.same({run_id='run', generation=2, reason='reason'},
            record.recover_executor)
        assert.same({run_id='run', generation=2, after_sequence=0},
            record.transport.expected)

        service = fixture({transport={snapshot={},
            scheduler={quarantine={active=false}}}})
        outcome = service.recover_executor({}, 'runner', 'run', 2, 'reason')
        assert.same(0, outcome.exit_code)
    end)
end)
