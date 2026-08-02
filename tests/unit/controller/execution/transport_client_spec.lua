-- Direct contracts for controller transport classification and parsing.

local module = require('dwarfspec.controller.execution.transport_client')
local json = require('dkjson')
local RunState = require('dwarfspec.protocol.enums.run_states')

---Creates a transport client with a minimal command builder.
---@return table
local function client()
    return module.new({
        builder={probe=function() return {'probe'} end,
            scheduler_status=function() return {'status'} end,
            query=function() return {'query'} end},
        failure=function(kind, message)
            return {kind=kind, message=message, exit_code=9}
        end,
        failure_kinds={DEPENDENCY='dependency', CONNECTION='connection',
            HOST='host', REGISTRATION='registration'},
        clean_message=tostring,
    })
end

---Builds one valid terminal transport at the requested cursor.
---@param after_sequence integer
---@return string[]
local function transport_lines(after_sequence)
    local snapshot = {
        schema='dwarfspec.run.v2', protocol_version=2,
        service_instance_id='service', project_id='project', run_id='run',
        state=RunState.PASSED, terminal=true, generation=1,
        submitted_at_ms=1, activated_at_ms=2, queue_wait_ms=1,
        last_sequence=after_sequence, owner_kind='external',
        counts={successes=1, failures=0, errors=0, pending=0},
        totals={successes=1, failures=0, errors=0, pending=0},
        queue_lease={active=false}, execution_lease={active=false},
        cleanup_confirmed=true, mount_cleanup_verified=true, failures={},
    }
    return {'DWARFSPEC_JSON ' .. json.encode({
        schema='dwarfspec.transport.v2', protocol=2,
        service_instance_id='service', project_id='project', run_id='run',
        generation=1, snapshot=snapshot, events={},
        last_sequence=after_sequence,
    })}
end

describe('controller transport client', function()
    it('classifies process exceptions and unhealthy probes as connection failures', function()
        local transport = client()
        local ok, detail = pcall(transport.verify_connection, {
            invoke=function() error('bridge unavailable') end}, 'runner')
        assert.is_false(ok)
        assert.same('connection', detail.kind)
        ok, detail = pcall(transport.verify_connection, {
            invoke=function() return {exit_code=0, lines={'wrong'}} end}, 'runner')
        assert.is_false(ok)
        assert.same('connection', detail.kind)
    end)

    it('accepts the exact healthy probe', function()
        local transport = client()
        local options = {invoke=function() return {exit_code=0, lines={
                'DWARFSPEC_PROBE protocol=2 core=true timeout=function'}} end}
        assert.has_no.errors(function() transport.verify_connection(options, 'runner') end)
    end)

    it('classifies nonzero exits before canonical parsing', function()
        local transport = client()
        local ok, detail = pcall(transport.transport, {
            invoke=function() return {exit_code=4, lines={}} end}, 'runner', {}, {}, 'poll')
        assert.is_false(ok)
        assert.same('host', detail.kind)
        assert.matches('poll exited with 4', detail.message)
    end)

    it('rejects missing and malformed canonical envelopes', function()
        local transport = client()
        local options = {invoke=function() return {exit_code=0, lines={}} end}
        local ok, detail = pcall(transport.transport, options, 'runner', {}, {}, 'poll')
        assert.is_false(ok)
        assert.matches('did not contain', tostring(detail))
        options.invoke = function()
            return {exit_code=0, lines={'DWARFSPEC_JSON not-json'}}
        end
        ok, detail = pcall(transport.transport, options, 'runner', {}, {}, 'poll')
        assert.is_false(ok)
        assert.matches('invalid DwarfSpec JSON', tostring(detail))
    end)

    it('enforces expected identities and polling cursors', function()
        local transport = client()
        local options = {invoke=function()
            return {exit_code=0, lines=transport_lines(4)}
        end}
        local expected = {service_instance_id='service', project_id='project',
            run_id='other', generation=1, after_sequence=4}
        local ok, detail = pcall(transport.transport, options, 'runner', {},
            expected, 'poll')
        assert.is_false(ok)
        assert.matches('identity mismatch: run_id', tostring(detail))
        expected.run_id = 'run'
        expected.after_sequence = 3
        ok, detail = pcall(transport.transport, options, 'runner', {}, expected,
            'poll')
        assert.is_false(ok)
        assert.matches('last sequence does not match', tostring(detail))
        expected.after_sequence = 4
        assert.has_no.errors(function()
            transport.transport(options, 'runner', {}, expected, 'poll')
        end)
    end)

    it('classifies process exceptions for every invocation path', function()
        local transport = client()
        local options = {invoke=function() error('process exception') end}
        local cases = {
            {kind='host', message='poll bridge failed', invoke=function()
                return transport.transport(options, 'runner', {}, {}, 'poll')
            end},
            {kind='registration', message='bootstrap bridge failed',
                retryable=true, invoke=function()
                    return transport.bootstrap_response(options, 'runner', {}, {})
                end},
            {kind='host', message='status bridge failed', invoke=function()
                return transport.scheduler_status(options, 'runner')
            end},
            {kind='host', message='history query bridge failed', invoke=function()
                return transport.query(options, 'runner', 'history', nil)
            end},
        }
        for _, case in ipairs(cases) do
            local ok, detail = pcall(case.invoke)
            assert.is_false(ok)
            assert.same(case.kind, detail.kind)
            assert.matches(case.message, detail.message)
            assert.same(case.retryable, detail.retryable)
        end
    end)
end)
