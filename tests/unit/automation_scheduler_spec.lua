-- Unit contracts for single-owner live automation scheduling.

local scheduler_module = assert(loadfile(
    'src/dwarfspec/automation/coroutine_scheduler.lua'))()

describe('automation scheduler', function()
    local now
    local current
    local callbacks
    local tick_callbacks
    local active
    local next_timeout_id
    local completion
    local run
    local scheduler

    before_each(function()
        now = 0
        current = true
        callbacks = {}
        tick_callbacks = {}
        active = {}
        next_timeout_id = 0
        completion = nil
        run = {suspended=false, outstanding_wait=nil}
        scheduler = scheduler_module.new(run, {
            is_current=function() return current end,
            schedule_timeout=function(delay, callback)
                assert.equals(1, delay)
                next_timeout_id = next_timeout_id + 1
                local id = next_timeout_id
                callbacks[id] = callback
                active[id] = callback
                return id
            end,
            schedule_tick_timeout=function(delay, callback)
                next_timeout_id = next_timeout_id + 1
                local id = next_timeout_id
                tick_callbacks[id] = {
                    delay=delay,
                    callback=callback,
                }
                active[id] = callback
                return id
            end,
            cancel_timeout=function(id) active[id] = nil end,
            now_ms=function() return now end,
            diagnostics=function()
                return {focus='dwarfmode/Default', screen='viewscreen_dwarfmodest'}
            end,
            on_complete=function(ok, value)
                completion = {ok=ok, value=value}
            end,
        })
    end)

    ---Starts one scheduler-owned test coroutine.
    ---@param action function
    ---@return thread, any
    local function start(action)
        local owner = coroutine.create(action)
        scheduler_module.bind(scheduler, owner)
        local ok, yielded = coroutine.resume(owner)
        assert.is_true(ok)
        return owner, yielded
    end

    it('resumes the sole owner after the requested raw frames', function()
        local result
        local owner, yielded = start(function()
            result = scheduler_module.wait_frames(scheduler, 2)
        end)
        assert.is_true(scheduler_module.owns_yield(scheduler, yielded))

        callbacks[1]()
        assert.equals('suspended', coroutine.status(owner))
        callbacks[2]()

        assert.equals('dead', coroutine.status(owner))
        assert.equals(2, result)
        assert.same({ok=true, value=nil}, completion)
        assert.is_nil(run.outstanding_wait)
    end)

    it('resumes after the requested unpaused simulation ticks', function()
        local result
        local owner, yielded = start(function()
            result = scheduler_module.wait_ticks(
                scheduler, 3, {timeout_ms=100})
        end)
        assert.is_true(scheduler_module.owns_yield(scheduler, yielded))
        assert.equals(3, tick_callbacks[1].delay)

        callbacks[2]()
        assert.equals('suspended', coroutine.status(owner))
        assert.is_not_nil(active[3])
        tick_callbacks[1].callback()

        assert.equals('dead', coroutine.status(owner))
        assert.equals(3, result)
        assert.is_nil(active[3])
        assert.is_nil(run.outstanding_wait)
    end)

    it('times out a simulation-tick wait while the game is paused', function()
        local wait_ok
        local wait_error
        start(function()
            wait_ok, wait_error = pcall(scheduler_module.wait_ticks,
                scheduler, 1, {timeout_ms=5})
        end)
        now = 6

        callbacks[2]()

        assert.is_false(wait_ok)
        assert.matches('operation="wait_ticks%(1%)"', wait_error)
        assert.matches('frame_budget=unlimited', wait_error, 1, true)
        assert.is_nil(active[1])
    end)

    it('returns the truthy value observed by wait_until', function()
        local observations = 0
        local result
        start(function()
            result = scheduler_module.wait_until(scheduler, 'ready value',
                function()
                    observations = observations + 1
                    return observations == 2 and 'ready' or false
                end)
        end)

        callbacks[1]()
        callbacks[2]()

        assert.equals('ready', result)
        assert.equals(2, observations)
        assert.is_true(completion.ok)
    end)

    it('raises an actionable frame-budget timeout inside the test', function()
        local wait_ok
        local wait_error
        start(function()
            wait_ok, wait_error = pcall(scheduler_module.wait_until,
                scheduler, 'missing target', function() return false end,
                {frame_budget=2, timeout_ms=100})
        end)

        callbacks[1]()
        callbacks[2]()

        assert.is_false(wait_ok)
        assert.matches('operation="missing target"', wait_error, 1, true)
        assert.matches('focus="dwarfmode/Default"', wait_error, 1, true)
        assert.matches('screen="viewscreen_dwarfmodest"', wait_error, 1, true)
        assert.matches('elapsed_frames=2', wait_error, 1, true)
        assert.matches('last_observed=false', wait_error, 1, true)
        assert.is_true(completion.ok)
    end)

    it('raises query failures as interaction errors', function()
        local wait_ok
        local wait_error
        start(function()
            wait_ok, wait_error = pcall(scheduler_module.wait_until,
                scheduler, 'broken query', function()
                    error('query exploded')
                end)
        end)

        callbacks[1]()

        assert.is_false(wait_ok)
        assert.matches('automation interaction error', wait_error, 1, true)
        assert.matches('cause=.*query exploded', wait_error)
        assert.is_true(completion.ok)
    end)

    it('enforces the wall-clock deadline independently of frame budget', function()
        local wait_ok
        local wait_error
        start(function()
            wait_ok, wait_error = pcall(scheduler_module.wait_until,
                scheduler, 'wall deadline', function() return nil end,
                {frame_budget=100, timeout_ms=5})
        end)
        now = 6

        callbacks[1]()

        assert.is_false(wait_ok)
        assert.matches('elapsed_ms=6', wait_error, 1, true)
        assert.matches('elapsed_frames=1', wait_error, 1, true)
    end)

    it('supports event waits without an arbitrary frame budget', function()
        local observed = false
        local result
        start(function()
            result = scheduler_module.wait_until(scheduler, 'map-loaded event',
                function() return observed end,
                {frame_budget=false, timeout_ms=false})
        end)

        callbacks[1]()
        assert.is_nil(completion)
        assert.is_nil(run.outstanding_wait.frame_budget)
        assert.is_nil(run.outstanding_wait.wall_timeout_ms)
        observed = 'loaded'
        callbacks[2]()

        assert.equals('loaded', result)
        assert.is_true(completion.ok)
    end)

    it('cancels a wait and rejects its stale callback', function()
        local owner = start(function()
            scheduler_module.wait_frames(scheduler, 3)
        end)
        local stale = callbacks[1]

        assert.is_true(scheduler_module.cancel(scheduler, 'abort proof'))
        assert.is_nil(active[1])
        assert.is_nil(run.outstanding_wait)
        stale()

        assert.equals('suspended', coroutine.status(owner))
        assert.equals(1, scheduler.stale_callback_count)
        assert.equals('abort proof',
            run.scheduler_state.cancellation_reason)
    end)

    it('rejects waits from any coroutine other than its owner', function()
        local owner = coroutine.create(function() end)
        scheduler_module.bind(scheduler, owner)

        assert.has_error(function()
            scheduler_module.wait_frames(scheduler, 1)
        end, 'ds waits must run inside the active automation suite coroutine')
    end)

    it('rejects a nested wait before scheduling another callback', function()
        local wait_ok
        local wait_error
        local owner = coroutine.create(function()
            scheduler.outstanding = {id='existing'}
            wait_ok, wait_error = pcall(
                scheduler_module.wait_frames, scheduler, 1)
        end)
        scheduler_module.bind(scheduler, owner)

        assert.is_true(coroutine.resume(owner))
        assert.is_false(wait_ok)
        assert.matches('nested automation waits are not supported',
            wait_error, 1, true)
        assert.equals(0, #callbacks)
    end)

    it('validates simulation tick counts before scheduling', function()
        local owner = coroutine.create(function() end)
        scheduler_module.bind(scheduler, owner)

        assert.has_error(function()
            scheduler_module.wait_ticks(scheduler, 0)
        end, 'simulation tick count must be a positive integer')
        assert.has_error(function()
            scheduler_module.wait_ticks(scheduler, 1.5)
        end, 'simulation tick count must be a positive integer')
        assert.equals(0, next_timeout_id)
    end)
end)
