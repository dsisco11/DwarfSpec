-- Unit contracts for single-owner live automation scheduling.

local scheduler_module = assert(loadfile(
    'Tests/Automation/support/scheduler.lua'))()

describe('automation scheduler', function()
    local now
    local current
    local callbacks
    local active
    local completion
    local run
    local scheduler

    before_each(function()
        now = 0
        current = true
        callbacks = {}
        active = {}
        completion = nil
        run = {suspended=false, outstanding_wait=nil}
        scheduler = scheduler_module.new(run, {
            is_current=function() return current end,
            schedule_timeout=function(delay, callback)
                assert.equals(1, delay)
                local id = #callbacks + 1
                callbacks[id] = callback
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
        end, 'dy waits must run inside the active automation suite coroutine')
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
end)
