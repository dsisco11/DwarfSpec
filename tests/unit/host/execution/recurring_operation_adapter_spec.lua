local module = require(
    'dwarfspec.host.execution.recurring_operation_adapter')

describe('host recurring operation adapter', function()
    ---Creates a native scheduling double and its adapter dependencies.
    ---@return table, table
    local function fixture()
        local state = {active=true, next_handle=0, scheduled={}, failures={}}
        local dependencies = {
            schedule_tick=function(delay, callback)
                assert.equals(1, delay)
                state.next_handle = state.next_handle + 1
                local handle = {id=state.next_handle}
                state.scheduled[handle] = callback
                return handle
            end,
            cancel_timeout=function(handle)
                state.scheduled[handle] = nil
            end,
            timeout_active=function(handle)
                return state.scheduled[handle] and handle or nil
            end,
            is_run_active=function() return state.active end,
            report_failure=function(message, trace)
                table.insert(state.failures, {message, trace})
            end,
        }
        return state, dependencies
    end

    it('uses opaque handles for scheduling cancellation and verification',
            function()
        local state, dependencies = fixture()
        local adapter = module.new(dependencies)
        local calls = 0
        local handle = adapter.schedule(function() calls = calls + 1 end)

        assert.is_true(adapter.is_scheduled(handle))
        state.scheduled[handle]()
        assert.equals(1, calls)
        adapter.cancel(handle)
        adapter.cancel(handle)
        assert.is_false(adapter.is_scheduled(handle))
    end)

    it('makes callbacks inert after active-run ownership ends', function()
        local state, dependencies = fixture()
        local adapter = module.new(dependencies)
        local calls = 0
        local handle = adapter.schedule(function() calls = calls + 1 end)
        state.active = false

        state.scheduled[handle]()

        assert.equals(0, calls)
        assert.is_nil(adapter.schedule(function() calls = calls + 1 end))
    end)

    it('reports at most one failure for the active run', function()
        local state, dependencies = fixture()
        local adapter = module.new(dependencies)

        assert.is_true(adapter.report_failure('first', 'trace'))
        assert.is_false(adapter.report_failure('second', 'trace'))
        state.active = false
        assert.is_false(adapter.report_failure('third', 'trace'))
        assert.same({{'first', 'trace'}}, state.failures)
    end)
end)
