-- Direct contracts for controller transport classification and parsing.

local module = require('dwarfspec.controller.execution.transport_client')
local json = require('dkjson')
local RunState = require('dwarfspec.protocol.enums.run_states')
local HEALTHY_PROBE =
    'DWARFSPEC_PROBE protocol=2 core=true timeout=function'

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

---Verifies that one simulated subprocess result passes connection preflight.
---@param lines any
local function assert_connection_success(lines)
    local transport = client()
    local options = {invoke=function()
        return {exit_code=0, lines=lines}
    end}
    assert.has_no.errors(function()
        transport.verify_connection(options, 'runner')
    end)
end

---Returns the bounded output excerpt from one missing-marker diagnostic.
---@param lines any
---@return string
local function output_excerpt(lines)
    return assert(connection_failure(lines).message:match('Output: (.*)$'))
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

    it('accepts a healthy probe as the only output line', function()
        assert_connection_success({HEALTHY_PROBE})
    end)

    it('accepts unrelated output before a healthy probe', function()
        assert_connection_success({'before', HEALTHY_PROBE})
    end)

    it('accepts unrelated output after a healthy probe', function()
        assert_connection_success({HEALTHY_PROBE, 'after'})
    end)

    it('ignores embedded markers and well-formed unknown fields', function()
        assert_connection_success({
            'prefix DWARFSPEC_PROBE protocol=999 core=false timeout=nil',
            'DWARFSPEC_PROBE timeout=function future=value protocol=2 core=true',
        })
    end)

    it('reports nonzero probe exits with empty and non-empty output', function()
        local detail = connection_failure({}, 17)
        assert.same('DFHack connection probe through "runner" exited with code 17. ' ..
            'Output: <no output>', detail.message)

        detail = connection_failure({
            HEALTHY_PROBE,
            'subprocess failed',
        }, 17)
        assert.same('DFHack connection probe through "runner" exited with code 17. ' ..
            'Output: ' .. HEALTHY_PROBE .. ' | subprocess failed', detail.message)
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

    it('reports expected and observed protocol values before health failures', function()
        local detail = connection_failure({
            'DWARFSPEC_PROBE protocol=3 core=false timeout=nil',
        })
        assert.same('DwarfSpec protocol mismatch: controller expects 2, probe ' ..
            'reported 3. Check for mixed installed DwarfSpec package versions.',
            detail.message)
    end)

    it('reports core=false independently from timeout health', function()
        local detail = connection_failure({
            'DWARFSPEC_PROBE protocol=2 core=false timeout=function',
        })
        assert.same('DFHack probe did not run in a healthy core Lua context: ' ..
            'expected core=true, reported core=false.', detail.message)
    end)

    it('reports every non-function timeout type independently', function()
        for _, timeout_type in ipairs({
                'nil', 'boolean', 'number', 'string', 'userdata', 'thread',
                'table', 'unavailable',
            }) do
            local detail = connection_failure({
                'DWARFSPEC_PROBE protocol=2 core=true timeout=' .. timeout_type,
            })
            assert.same('DFHack core Lua context is missing the required ' ..
                'dfhack.timeout function: reported timeout=' .. timeout_type .. '.',
                detail.message)
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

    it('enforces exact line-count and byte truncation boundaries', function()
        local lines = {}
        for index = 1, 8 do lines[index] = 'line-' .. index end
        assert.same(table.concat(lines, ' | '), output_excerpt(lines))

        table.insert(lines, 'line-9')
        assert.same('<1 earlier lines omitted> | ' ..
            table.concat({table.unpack(lines, 2, 9)}, ' | '),
            output_excerpt(lines))

        local exact_line = string.rep('x', 512)
        assert.same(exact_line, output_excerpt({exact_line}))
        local truncated_line = output_excerpt({string.rep('x', 513)})
        assert.same(512, #truncated_line)
        assert.is_truthy(truncated_line:find('...<line truncated>', 1, true))

        lines = {}
        for index = 1, 7 do lines[index] = string.rep('x', 253) end
        lines[8] = string.rep('x', 256)
        local exact_output = output_excerpt(lines)
        assert.same(2048, #exact_output)
        assert.is_falsy(exact_output:find('<output truncated> ', 1, true))

        lines[8] = string.rep('x', 257)
        local truncated_output = output_excerpt(lines)
        assert.same(2048, #truncated_output)
        assert.same('<output truncated> ', truncated_output:sub(1, 19))
        assert.same(lines[8], truncated_output:sub(-#lines[8]))
    end)

    it('preserves structured errors from nonzero subprocess results', function()
        local lines = {'DWARFSPEC_JSON ' .. json.encode({
            schema='dwarfspec.error.v1', protocol=2,
            kind='registration', code='package_version_mismatch',
            message='different version loaded',
            running_version='0.2.1', requested_version='0.2.2',
        })}
        local transport = client()
        local ok, detail = pcall(transport.transport, {
            invoke=function() return {exit_code=4, lines=lines} end,
        }, 'runner', {}, {}, 'poll')
        assert.is_false(ok)
        assert.equals('package_version_mismatch', detail.code)
        assert.equals('0.2.1', detail.running_version)

        local response, owner, bootstrap_error = transport.bootstrap_response({
            invoke=function() return {exit_code=4, lines=lines} end,
        }, 'runner', {}, {})
        assert.is_nil(response)
        assert.is_nil(owner)
        assert.equals('package_version_mismatch', bootstrap_error.code)
    end)

    it('classifies zero-exit mutation rejections with actionable safe context',
            function()
        local cases = {
            {code='service_not_loaded', operation='abort',
                guidance='Bootstrap DwarfSpec'},
            {code='run_not_found', operation='cancel', run_id='run-1',
                guidance='refresh status before retrying cancel'},
            {code='generation_mismatch', operation='acknowledgement',
                run_id='run-1', generation=2, current_generation=3,
                guidance='requested generation 2, current generation 3'},
            {code='invalid_run_state', operation='discard', run_id='run-1',
                generation=3, state='running', guidance='is running'},
            {code='owner_capability_rejected', operation='recover',
                run_id='run-1', generation=3, state='running',
                guidance='owning DwarfSpec process'},
            {code='quarantine_mismatch', operation='recover executor',
                run_id='run-1', generation=3, blocking_run_id='run-2',
                blocking_generation=4,
                guidance='belongs to run run-2 generation 4'},
            {code='clean_state_unverified', operation='recover executor',
                run_id='run-1', generation=3, reason='cleanup remains active',
                guidance='Resolve remaining live resources'},
        }
        for _, case in ipairs(cases) do
            local response = {schema='dwarfspec.error.v1', protocol=2,
                kind='host', message='opaque host prose'}
            for name, value in pairs(case) do
                if name ~= 'guidance' then response[name] = value end
            end
            local transport = client()
            local ok, detail = pcall(transport.transport, {
                invoke=function()
                    return {exit_code=0, lines={
                        'DWARFSPEC_JSON ' .. json.encode(response),
                    }}
                end,
            }, 'runner', {}, {}, case.operation)
            assert.is_false(ok, case.code)
            assert.equals(case.code, detail.code)
            assert.equals('host', detail.kind)
            assert.equals(9, detail.exit_code)
            assert.is_truthy(detail.message:find('opaque host prose', 1, true))
            assert.is_nil(detail.owner_capability)
            assert.is_nil(detail.authorization_proof)
            assert.is_truthy(detail.message:find(case.guidance, 1, true),
                case.code)
            for name, value in pairs(case) do
                if name ~= 'guidance' then
                    assert.equals(value, detail[name], case.code .. '.' .. name)
                end
            end
            if case.run_id then
                assert.is_truthy(detail.message:find(case.run_id, 1, true),
                    case.code)
            end
        end
    end)

    it('classifies nonzero exits without valid JSON using bounded output', function()
        local transport = client()
        local ok, detail = pcall(transport.transport, {
            invoke=function()
                return {exit_code=4, lines={string.rep('x', 3000)}}
            end}, 'runner', {}, {}, 'poll')
        assert.is_false(ok)
        assert.same('host', detail.kind)
        assert.matches('poll exited with 4', detail.message)
        assert.matches('Output:', detail.message, 1, true)
        assert.is_true(#detail.message < 2200)

        local malformed = {'DWARFSPEC_JSON ' .. json.encode({
            schema='dwarfspec.error.v1', protocol=2,
            kind='registration', code='package_version_mismatch',
            message='different version loaded', running_version='0.2.1',
        })}
        ok, detail = pcall(transport.transport, {
            invoke=function() return {exit_code=4, lines=malformed} end,
        }, 'runner', {}, {}, 'poll')
        assert.is_false(ok)
        assert.equals('host', detail.kind)
        assert.is_nil(detail.code)
        assert.matches('DWARFSPEC_JSON', detail.message, 1, true)
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
