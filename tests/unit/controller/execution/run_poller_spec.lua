-- Direct contracts for cursor-aware run polling and timeout budgets.

local module = require('dwarfspec.controller.execution.run_poller')
local RunState = require('dwarfspec.protocol.enums.run_states')

---Creates a poller and an observation record over supplied transports.
---@param transports table[]
---@return table, table
local function fixture(transports)
    local record = {polls={}, invocations={}, formatted={}}
    local builder = {poll=function(_, run_id, owner_capability, cursor,
            generation)
        local arguments = {'poll', run_id, owner_capability, tostring(cursor),
            tostring(generation)}
        table.insert(record.polls, arguments)
        return arguments
    end}
    local client = {transport=function(_, _, arguments, expected)
        table.insert(record.invocations, {arguments=arguments, expected=expected})
        return table.remove(transports, 1)
    end}
    local poller = module.new({builder=builder, client=client,
        format_events=function(events)
            table.insert(record.formatted, events)
            local lines = {}
            for _, event in ipairs(events) do table.insert(lines, event.line) end
            return lines
        end,
        fail=function(kind, message) error({kind=kind, message=message}, 0) end,
        failure_kinds={HOST='host', QUEUE_TIMEOUT='queue', TIMEOUT='execution'},
        clean_message=tostring})
    return poller, record
end

---Creates a complete polling scope and its observable effects.
---@param overrides table|nil
---@return table, table
local function scope(overrides)
    local record = {activated=0, emitted={}, persisted={}, observed={}}
    local activated_at
    local value = {
        options={poll_interval_ms=1, timeout_seconds=10,
            project_root='project'},
        runner='runner', run_id='run', owner_capability='owner',
        report={state=RunState.QUEUED, terminal=false}, cursor=4,
        queue_started_at=0, now=function() return 1 end,
        sleep=function() end,
        expectation=function(cursor)
            return {after_sequence=cursor, generation=3}
        end,
        journal={}, activated_at=function() return activated_at end,
        entered_executor=function(report) return report.activated_at_ms ~= nil end,
        activate=function()
            record.activated = record.activated + 1
            activated_at = 'activated'
            return 1
        end,
        error_format='plain', emit=function(line)
            table.insert(record.emitted, line)
        end,
        formatting_failed=function() record.formatting_failed=true end,
        persist=function(report) table.insert(record.persisted, report.state) end,
        observe=function(report, cursor)
            table.insert(record.observed, {state=report.state, cursor=cursor})
        end,
    }
    for name, field in pairs(overrides or {}) do value[name] = field end
    return value, record
end

describe('controller run poller', function()
    it('renews the lease, advances cursors, activates once, and emits observations in order', function()
        local poller, calls = fixture({
            {snapshot={state=RunState.RUNNING, terminal=false,
                activated_at_ms=1}, events={{line='first'}}, last_sequence=5},
            {snapshot={state=RunState.PASSED, terminal=true,
                activated_at_ms=1}, events={{line='second'}}, last_sequence=6},
        })
        local value, observed = scope()
        local outcome = poller.until_terminal(value)
        assert.same(RunState.PASSED, outcome.report.state)
        assert.same(6, outcome.cursor)
        assert.same({
            {'poll', 'run', 'owner', '4', '3'},
            {'poll', 'run', 'owner', '5', '3'},
        }, calls.polls)
        assert.same({after_sequence=4, generation=3},
            calls.invocations[1].expected)
        assert.same({after_sequence=5, generation=3},
            calls.invocations[2].expected)
        assert.same(1, observed.activated)
        assert.same({'first', 'second'}, observed.emitted)
        assert.same({RunState.RUNNING, RunState.PASSED}, observed.persisted)
        assert.same({'first', 'second'}, {
            value.journal[1].line, value.journal[2].line})
        assert.same({
            {state=RunState.RUNNING, cursor=5},
            {state=RunState.PASSED, cursor=6},
        }, observed.observed)
    end)

    it('distinguishes queue and execution timeout budgets', function()
        local poller = fixture({})
        local value = scope({now=function() return 2 end})
        value.options.queue_timeout_seconds = 1
        local ok, detail = pcall(poller.until_terminal, value)
        assert.is_false(ok)
        assert.same('queue', detail.kind)

        value = scope({now=function() return 2 end,
            report={state=RunState.RUNNING, terminal=false},
            execution_started_at=0})
        value.options.timeout_seconds = 2
        ok, detail = pcall(poller.until_terminal, value)
        assert.is_false(ok)
        assert.same('execution', detail.kind)
    end)

    it('propagates interruption before another transport invocation', function()
        local poller, calls = fixture({})
        local value = scope({report={state=RunState.RUNNING, terminal=false},
            execution_started_at=0,
            sleep=function() error('interrupt') end})
        local ok, detail = pcall(poller.until_terminal, value)
        assert.is_false(ok)
        assert.matches('interrupt', tostring(detail))
        assert.same({}, calls.invocations)
    end)

    it('does not advance cursor or observations after a rejected poll', function()
        local detail = {kind='host', code='event_cursor_ahead',
            message='requested cursor 8, retained cursor 7'}
        local poller = module.new({
            builder={poll=function() return {'poll'} end},
            client={transport=function() error(detail, 0) end},
            format_events=function() return {} end,
            fail=function(kind, message)
                error({kind=kind, message=message}, 0)
            end,
            failure_kinds={HOST='host'}, clean_message=tostring,
        })
        local value, observed = scope()
        local original_report = value.report
        local ok, rejection = pcall(poller.until_terminal, value)
        assert.is_false(ok)
        assert.equals('event_cursor_ahead', rejection.code)
        assert.equals(4, value.cursor)
        assert.equals(original_report, value.report)
        assert.same({}, value.journal)
        assert.same({}, observed.persisted)
        assert.same({}, observed.observed)
        assert.same({}, observed.emitted)
    end)

    it('classifies formatting failures before persistence', function()
        local poller = module.new({builder={}, client={},
            format_events=function() error('formatter failed') end,
            fail=function(kind, message) error({kind=kind, message=message}, 0) end,
            failure_kinds={HOST='host'}, clean_message=tostring})
        local value, observed = scope()
        local ok, detail = pcall(poller.consume, value, {
            snapshot={state=RunState.QUEUED}, events={{line='event'}},
            last_sequence=5}, true)
        assert.is_false(ok)
        assert.same('host', detail.kind)
        assert.is_true(observed.formatting_failed)
        assert.same({}, observed.persisted)
    end)
end)
