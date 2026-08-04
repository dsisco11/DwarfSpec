local module = require('dwarfspec.driver.simulation.recurring_operation')

describe('driver recurring operation', function()
    ---Creates one deterministic scheduler and cleanup double.
    ---@return table, table
    local function fixture()
        local state = {
            active_run=true,
            next_handle=0,
            scheduled={},
            cancelled={},
            cleanups={},
            failures={},
            reject_schedule=false,
            reject_cancel=false,
        }
        local dependencies = {
            schedule=function(callback)
                if state.reject_schedule then return nil end
                state.next_handle = state.next_handle + 1
                local handle = {id=state.next_handle}
                state.scheduled[handle] = callback
                return handle
            end,
            cancel=function(handle)
                table.insert(state.cancelled, handle)
                if not state.reject_cancel then state.scheduled[handle] = nil end
            end,
            is_scheduled=function(handle)
                return state.scheduled[handle] ~= nil
            end,
            report_failure=function(message, trace)
                table.insert(state.failures, {message=message, trace=trace})
            end,
            register_cleanup=function(name, callback)
                table.insert(state.cleanups, {name=name, callback=callback})
            end,
        }
        return state, dependencies
    end

    ---Fires one native handle after removing it from scheduled state.
    ---@param state table
    ---@param handle table
    local function fire(state, handle)
        local callback = assert(state.scheduled[handle])
        state.scheduled[handle] = nil
        callback()
    end

    it('registers ownership before scheduling and recurs by opaque handle',
            function()
        local state, dependencies = fixture()
        local order = {}
        local original_schedule = dependencies.schedule
        dependencies.register_cleanup=function(name, callback)
            table.insert(order, 'cleanup')
            table.insert(state.cleanups, {name=name, callback=callback})
        end
        dependencies.schedule=function(callback)
            table.insert(order, 'schedule')
            return original_schedule(callback)
        end
        local controller = module.new(dependencies)
        local calls = 0

        controller:start(function() calls = calls + 1 end, {9, 4})
        local first = controller.handle
        fire(state, first)

        assert.same({'cleanup', 'schedule', 'schedule'}, order)
        assert.equals(1, calls)
        assert.not_equals(first, controller.handle)
        assert.same({9, 4}, controller.retained_ids)
        assert.is_true(controller:cleanup_state().unit_speed_active)
    end)

    it('cancels idempotently and makes stale generations no-ops', function()
        local state, dependencies = fixture()
        local controller = module.new(dependencies)
        local calls = 0
        controller:start(function() calls = calls + 1 end)
        local stale_callback = state.scheduled[controller.handle]

        assert.is_true(controller:stop())
        assert.is_false(controller:stop())
        stale_callback()

        assert.equals(0, calls)
        assert.equals(1, #state.cancelled)
        assert.is_false(controller:cleanup_state().unit_speed_active)
    end)

    it('contains callback faults, reports once, and never reschedules',
            function()
        local state, dependencies = fixture()
        local controller = module.new(dependencies)
        controller:start(function() error('adapter exploded') end, {7})

        fire(state, controller.handle)

        assert.equals(1, #state.failures)
        assert.matches('adapter exploded', state.failures[1].trace, 1, true)
        assert.is_nil(controller.handle)
        assert.is_false(controller.active)
        assert.same({}, controller.retained_ids)
        assert.is_false(controller:cleanup_state().unit_speed_active)
    end)

    it('fails boundedly when initial or later scheduling is rejected',
            function()
        local state, dependencies = fixture()
        state.reject_schedule = true
        local controller = module.new(dependencies)
        assert.has_error(function()
            controller:start(function() end)
        end, 'DFHack rejected the recurring simulation-tick callback')
        assert.equals(1, #state.failures)
        assert.is_false(controller:cleanup_state().unit_speed_active)

        state, dependencies = fixture()
        controller = module.new(dependencies)
        controller:start(function() state.reject_schedule = true end)
        fire(state, controller.handle)
        assert.equals(1, #state.failures)
        assert.is_false(controller:cleanup_state().unit_speed_active)
    end)

    it('retains observable ownership when cancellation is rejected',
            function()
        local state, dependencies = fixture()
        local controller = module.new(dependencies)
        controller:start(function() end, {3})
        state.reject_cancel = true

        assert.has_error(function() state.cleanups[1].callback() end,
            'recurring operation callback remains scheduled')
        local cleanup_state = controller:cleanup_state()
        assert.is_true(cleanup_state.unit_speed_active)
        assert.is_true(cleanup_state.callback_scheduled)
        assert.is_true(cleanup_state.ownership_active)
        assert.equals(1, cleanup_state.retained_id_count)

        fire(state, controller.handle)
        assert.same({}, state.scheduled)
        assert.is_true(controller:cleanup_state().unit_speed_active)
    end)

    it('lets LIFO cleanup continue after cancellation rejection', function()
        local cleanup = require('dwarfspec.host.execution.cleanup')
        local state, dependencies = fixture()
        local registry = cleanup.new({})
        local restored = false
        cleanup.push(registry, 'later restoration', function()
            restored = true
        end)
        dependencies.register_cleanup=function(name, callback)
            return cleanup.push(registry, name, callback)
        end
        local controller = module.new(dependencies)
        controller:start(function() end)
        state.reject_cancel = true

        local ok, failures = cleanup.run(registry, 'abort')

        assert.is_false(ok)
        assert.is_true(restored)
        assert.equals(1, #failures)
        assert.equals('unit speed recurring operation', failures[1].name)
        assert.is_true(controller:cleanup_state().unit_speed_active)
    end)

    it('supports cleanup for every terminal reason without global residue',
            function()
        for _, reason in ipairs({
            'success', 'assertion failure', 'command timeout',
            'explicit abort', 'world unload',
        }) do
            local state, dependencies = fixture()
            local controller = module.new(dependencies)
            controller:start(function() end, {1, 2})

            state.cleanups[1].callback(reason)

            assert.is_false(controller:cleanup_state().unit_speed_active)
            assert.same({}, state.scheduled)
        end
    end)

    it('does not carry callback faults into a later controller', function()
        local state, dependencies = fixture()
        local first = module.new(dependencies)
        first:start(function() error('first run failure') end)
        fire(state, first.handle)

        local second = module.new(dependencies)
        local calls = 0
        second:start(function() calls = calls + 1 end)
        fire(state, second.handle)

        assert.equals(1, #state.failures)
        assert.equals(1, calls)
        assert.is_nil(second.fault)
    end)

end)
