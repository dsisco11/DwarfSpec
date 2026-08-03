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

---Captures one connection failure for a simulated subprocess result.
---@param lines any
---@param exit_code any|nil
---@return table
local function connection_failure(lines, exit_code)
    local transport = client()
    local ok, detail = pcall(transport.verify_connection, {
        invoke=function()
            return {exit_code=exit_code == nil and 0 or exit_code, lines=lines}
        end,
    }, 'runner')
    assert.is_false(ok)
    assert.same('connection', detail.kind)
    return detail
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
    it('classifies probe invocation exceptions separately', function()
        local transport = client()
        local ok, detail = pcall(transport.verify_connection, {
            invoke=function() error('bridge unavailable') end}, 'runner')
        assert.is_false(ok)
        assert.same('connection', detail.kind)
        assert.is_truthy(detail.message:find(
            'Could not invoke DFHack runner "runner":', 1, true))
        assert.is_truthy(detail.message:find('bridge unavailable', 1, true))
    end)

    it('accepts one healthy probe among unrelated output', function()
        local transport = client()
        local options = {invoke=function() return {exit_code=0, lines={
                'before',
                'prefix DWARFSPEC_PROBE protocol=999 core=false timeout=nil',
                'DWARFSPEC_PROBE timeout=function future=value protocol=2 core=true',
                'after'}} end}
        assert.has_no.errors(function() transport.verify_connection(options, 'runner') end)
    end)

    it('reports nonzero probe exits before parsing marker output', function()
        local detail = connection_failure({
            'DWARFSPEC_PROBE protocol=2 core=true timeout=function',
            'subprocess failed',
        }, 17)
        assert.same('DFHack connection probe through "runner" exited with code 17. ' ..
            'Output: DWARFSPEC_PROBE protocol=2 core=true timeout=function | ' ..
            'subprocess failed', detail.message)
    end)

    it('distinguishes missing and multiple probe reports', function()
        local no_output_message = 'DFHack responded through "runner", but emitted ' ..
            'no DwarfSpec probe report. Output: <no output>'
        assert.same(no_output_message, connection_failure(nil).message)
        assert.same(no_output_message, connection_failure({}).message)

        local detail = connection_failure({'ordinary DFHack output'})
        assert.same('DFHack responded through "runner", but emitted no DwarfSpec ' ..
            'probe report. Output: ordinary DFHack output', detail.message)

        detail = connection_failure({
            'DWARFSPEC_PROBE protocol=2 core=true timeout=function',
            'DWARFSPEC_PROBE protocol=2 core=true timeout=function',
        })
        assert.same('DFHack emitted 2 DwarfSpec probe reports; expected exactly ' ..
            'one. Output: DWARFSPEC_PROBE protocol=2 core=true timeout=function | ' ..
            'DWARFSPEC_PROBE protocol=2 core=true timeout=function', detail.message)
    end)

    it('reports malformed probe fields with specific context', function()
        local cases = {
            {'DWARFSPEC_PROBE protocol', 'invalid token: protocol'},
            {'DWARFSPEC_PROBE Protocol=2 core=true timeout=function',
                'invalid field name: Protocol'},
            {'DWARFSPEC_PROBE protocol= core=true timeout=function',
                'empty value for field protocol'},
            {'DWARFSPEC_PROBE protocol=2 protocol=3 core=true timeout=function',
                'duplicate field: protocol'},
            {'DWARFSPEC_PROBE core=true timeout=function',
                'missing required field: protocol'},
            {'DWARFSPEC_PROBE protocol=02 core=true timeout=function',
                'invalid protocol value: 02'},
            {'DWARFSPEC_PROBE protocol=2 core=yes timeout=function',
                'invalid core value: yes'},
            {'DWARFSPEC_PROBE protocol=2 core=true timeout=callable',
                'invalid timeout value: callable'},
            {'DWARFSPEC_PROBE protocol=2 core=true timeout=function future=bad/value',
                'invalid value for field future: bad/value'},
        }
        for _, case in ipairs(cases) do
            local detail = connection_failure({case[1]})
            assert.is_truthy(detail.message:find(
                'DFHack emitted a malformed DwarfSpec probe report: ' .. case[2],
                1, true), case[1])
            assert.is_truthy(detail.message:find('Probe: ' .. case[1], 1, true),
                case[1])
        end
    end)

    it('classifies protocol, core, and timeout health independently', function()
        local cases = {
            {
                'DWARFSPEC_PROBE protocol=3 core=false timeout=nil',
                'DwarfSpec protocol mismatch: controller expects 2, probe reported 3. ' ..
                    'Check for mixed installed DwarfSpec package versions.',
            },
            {
                'DWARFSPEC_PROBE protocol=2 core=unavailable timeout=nil',
                'DFHack probe did not run in a healthy core Lua context: expected ' ..
                    'core=true, reported core=unavailable.',
            },
            {
                'DWARFSPEC_PROBE protocol=2 core=true timeout=nil',
                'DFHack core Lua context is missing the required dfhack.timeout ' ..
                    'function: reported timeout=nil.',
            },
        }
        for _, case in ipairs(cases) do
            assert.same(case[2], connection_failure({case[1]}).message)
        end
    end)

    it('bounds and sanitizes sparse non-string probe output', function()
        local unprintable = setmetatable({}, {
            __tostring=function() error('cannot render') end,
        })
        local lines = {
            [1]='  first\tline\1  ',
            [3]=unprintable,
            [5]=string.rep('x', 600),
        }
        local detail = connection_failure(lines)
        assert.is_truthy(detail.message:find('first line?', 1, true))
        assert.is_truthy(detail.message:find('<unprintable output>', 1, true))
        assert.is_truthy(detail.message:find('...<line truncated>', 1, true))

        detail = connection_failure({string.rep('\195\169', 300)})
        local output = assert(detail.message:match('Output: (.*)$'))
        assert.is_not_nil(utf8.len(output))
        assert.is_true(#output <= 512)
    end)

    it('retains recent probe output within line and total byte limits', function()
        local lines = {}
        for index = 1, 10 do
            lines[index] = ('line-%02d-%s'):format(index, string.rep('x', 500))
        end
        local detail = connection_failure(lines)
        local output = assert(detail.message:match('Output: (.*)$'))
        assert.is_true(#output <= 2048)
        assert.is_truthy(output:find('<output truncated> ', 1, true))
        assert.is_falsy(output:find('line-01-', 1, true))
        assert.is_truthy(output:find('line-10-', 1, true))
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
