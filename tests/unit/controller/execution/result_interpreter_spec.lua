-- Direct contracts for stable invocation-result interpretation.

local module = require('dwarfspec.controller.execution.result_interpreter')
local ResultState = require('dwarfspec.protocol.enums.result_states')
local RunState = require('dwarfspec.protocol.enums.run_states')

local kinds = {SUCCESS='success', USAGE='usage', TEST='test',
    DEPENDENCY='dependency', CONNECTION='connection',
    QUEUE_TIMEOUT='queue', EXECUTOR_QUARANTINED='quarantine',
    TIMEOUT='timeout', REGISTRATION='registration', ABORTED='aborted',
    CANCELLED='cancelled', HOST='host'}

---Creates the interpreter with representative runner enumerations.
---@return table
local function interpreter()
    return module.new({failure_kinds=kinds,
        exit_codes={success=0, test=6}})
end

describe('controller result interpreter', function()
    it('maps every applicable runner failure kind and interruptions', function()
        local value = interpreter()
        local expected = {
            usage=ResultState.USAGE_ERROR,
            dependency=ResultState.DEPENDENCY_ERROR,
            connection=ResultState.CONNECTION_ERROR,
            registration=ResultState.REGISTRATION_ERROR,
            quarantine=ResultState.EXECUTOR_QUARANTINED,
            queue=ResultState.QUEUE_TIMEOUT,
            timeout=ResultState.TIMEOUT,
            cancelled=ResultState.CANCELLED,
            host=ResultState.HOST_ERROR,
        }
        for kind, state in pairs(expected) do
            assert.same(state, value.failure_state({kind=kind}, nil, false))
        end
        assert.same(ResultState.INTERRUPTED,
            value.failure_state({kind=kinds.HOST}, nil, true))
        assert.same(ResultState.HOST_ERROR,
            value.failure_state({kind=kinds.TEST}, nil, false))
        assert.same(RunState.FAILED, value.failure_state({kind=kinds.TEST},
            {state=RunState.FAILED}, false))
        assert.same(ResultState.FAILED,
            value.failure_state({kind=kinds.TEST},
                {state=RunState.PASSED}, false))
        assert.same(ResultState.ABORTED,
            value.failure_state({kind=kinds.ABORTED},
                {state=RunState.ABORTED}, false))
    end)

    it('classifies every native terminal outcome', function()
        local value = interpreter()
        local cases = {
            {report={state=RunState.PASSED, cleanup_confirmed=true}},
            {report={state=RunState.ABORTED}, kind=kinds.ABORTED,
                message='DwarfSpec run was aborted'},
            {report={state=RunState.CANCELLED}, kind=kinds.CANCELLED,
                message='DwarfSpec run was cancelled before activation'},
            {report={state=RunState.FAILED}, kind=kinds.TEST,
                message='DwarfSpec run finished with state failed'},
            {report={state=RunState.PASSED, cleanup_confirmed=false},
                kind=kinds.TEST,
                message='DwarfSpec run passed without confirmed cleanup'},
        }
        for _, case in ipairs(cases) do
            local kind, message = value.classify_native(case.report)
            assert.same(case.kind, kind)
            assert.same(case.message, message)
        end
    end)

    it('builds complete terminal invocation metadata', function()
        local value = interpreter()
        local native = {
            service_instance_id='service', project_id='project', run_id='run',
            generation=2, state=RunState.FAILED, activated_at_ms=1,
            queue_wait_ms=7,
        }
        local runner_error = {kind=kinds.TEST, message='native failure'}
        local document = value.build({project_root='project/../project',
            identities={'tests/a.ds.lua'}}, native, ResultState.FAILED, true,
            6, 'submitted', 'activated', 'finished', runner_error, {})
        assert.same('service', document.service_instance_id)
        assert.same('project', document.project_id)
        assert.same('run', document.run_id)
        assert.same(2, document.generation)
        assert.same(ResultState.FAILED, document.state)
        assert.is_true(document.terminal)
        assert.same(6, document.exit_code)
        assert.same({'tests/a.ds.lua'}, document.selection.identities)
        assert.same('submitted', document.submitted_at)
        assert.same('activated', document.activated_at)
        assert.same('finished', document.finished_at)
        assert.same(7, document.queue_wait_ms)
        assert.same({kind=kinds.TEST, message='native failure'}, document.error)
        assert.same(native, document.host_report)
        assert.same({}, document.events)
    end)

    it('honors no-file and file persistence policies and forwards writer options', function()
        local value = interpreter()
        local calls = 0
        value.persist({result_store={write=function() calls=calls+1 end}}, {})
        assert.same(0, calls)

        local received
        local options = {result_path='result.json', filesystem='filesystem',
            open_result_file='open', remove_result_file='remove',
            replace_result_file='replace', encode_result='encode',
            result_store={write=function(path, result, writer_options)
                received={path=path, result=result, options=writer_options}
            end}}
        local document = {state='result'}
        value.persist(options, document)
        assert.same('result.json', received.path)
        assert.same(document, received.result)
        assert.same({filesystem='filesystem', open_file='open',
            remove_file='remove', replace_file='replace', encode='encode'},
            received.options)

        options.result_store.write = function() error('write failed') end
        assert.has_error(function() value.persist(options, document) end)
    end)
end)
