-- Unit contracts for single-owner live automation scheduling.

local scheduler_module = assert(loadfile(
    'src/dwarfspec/automation/coroutine_scheduler.lua'))()

describe('automation scheduler', function()
    local now
    local current
    local callbacks
    local tick_callbacks
    local active
    local reject_frame_timeout
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
        reject_frame_timeout = false
        next_timeout_id = 0
        completion = nil
        run = {suspended=false, outstanding_wait=nil}
        scheduler = scheduler_module.new(run, {
            is_current=function() return current end,
            schedule_timeout=function(delay, callback)
                assert.equals(1, delay)
                if reject_frame_timeout then return nil end
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

    ---Creates one immutable event occurrence fixture.
    ---@param event string
    ---@param sequence integer
    ---@return table
    local function occurrence(event, sequence)
        local data = {
            event=event,
            source='state_change',
            payload={sequence=sequence},
        }
        return setmetatable({}, {
            __index=data,
            __newindex=function()
                error('event occurrence is immutable')
            end,
            __metatable=false,
        })
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

    it('supports query waits without an arbitrary frame budget', function()
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

    it('defers a synchronously signaled event to the next safe pump',
            function()
        local cleanup_count = 0
        local result
        local expected = occurrence('map_loaded', 1)
        local owner = start(function()
            result = scheduler_module.wait_event(scheduler, 'map_loaded', {
                description='load selected save',
                arm=function(identity)
                    assert.is_true(scheduler_module.signal_event(
                        scheduler, identity, expected))
                end,
                cleanup=function()
                    cleanup_count = cleanup_count + 1
                end,
            })
        end)

        assert.equals('suspended', coroutine.status(owner))
        assert.is_nil(result)
        assert.is_nil(completion)
        assert.equals(0, cleanup_count)
        callbacks[1]()

        assert.equals('dead', coroutine.status(owner))
        assert.equals(expected, result)
        assert.equals(1, cleanup_count)
        assert.same({ok=true, value=nil}, completion)
    end)

    it('assigns a distinct identity to every event wait', function()
        local identities = {}
        local cleanup_count = 0
        local owner = start(function()
            scheduler_module.wait_event(scheduler, 'paused', {
                arm=function(identity)
                    table.insert(identities, identity)
                    assert.is_true(scheduler_module.signal_event(
                        scheduler, identity, occurrence('paused', 1)))
                end,
                cleanup=function()
                    cleanup_count = cleanup_count + 1
                end,
            })
            scheduler_module.wait_event(scheduler, 'unpaused', {
                arm=function(identity)
                    table.insert(identities, identity)
                    assert.is_true(scheduler_module.signal_event(
                        scheduler, identity, occurrence('unpaused', 2)))
                end,
                cleanup=function()
                    cleanup_count = cleanup_count + 1
                end,
            })
        end)

        callbacks[1]()
        assert.equals('suspended', coroutine.status(owner))
        callbacks[2]()

        assert.equals('dead', coroutine.status(owner))
        assert.equals(2, #identities)
        assert.is_not.equal(identities[1], identities[2])
        assert.equals(2, cleanup_count)
    end)

    it('ignores unrelated and duplicate event signals', function()
        local identity
        local result
        local first = occurrence('paused', 1)
        local duplicate = occurrence('paused', 2)
        start(function()
            result = scheduler_module.wait_event(scheduler, 'paused', {
                arm=function(value) identity = value end,
                cleanup=function() end,
            })
        end)

        assert.is_false(scheduler_module.signal_event(
            scheduler, identity, occurrence('unpaused', 0)))
        assert.equals(0, #callbacks)
        assert.is_true(scheduler_module.signal_event(
            scheduler, identity, first))
        assert.is_false(scheduler_module.signal_event(
            scheduler, identity, duplicate))
        callbacks[1]()

        assert.equals(first, result)
        assert.is_true(completion.ok)
    end)

    it('does not consume a signal when its safe pump is rejected',
            function()
        local identity
        local result
        local first = occurrence('paused', 1)
        local second = occurrence('paused', 2)
        reject_frame_timeout = true
        start(function()
            result = scheduler_module.wait_event(scheduler, 'paused', {
                arm=function(value)
                    identity = value
                    assert.is_false(scheduler_module.signal_event(
                        scheduler, identity, first))
                end,
                cleanup=function() end,
            })
        end)

        assert.is_false(run.outstanding_wait.signaled)
        assert.is_nil(run.outstanding_wait.occurrence)
        reject_frame_timeout = false
        assert.is_true(scheduler_module.signal_event(
            scheduler, identity, second))
        callbacks[1]()

        assert.equals(second, result)
        assert.is_true(completion.ok)
    end)

    it('does not schedule a command-local timeout by default', function()
        local identity
        local cleanup_count = 0
        start(function()
            scheduler_module.wait_event(scheduler, 'world_loaded', {
                arm=function(value) identity = value end,
                cleanup=function()
                    cleanup_count = cleanup_count + 1
                end,
            })
        end)

        assert.is_not_nil(identity)
        assert.equals(0, #callbacks)
        assert.is_nil(run.outstanding_wait.wall_timeout_ms)
        assert.is_true(scheduler_module.cancel(scheduler, 'test end'))
        assert.equals(1, cleanup_count)
    end)

    it('supports explicitly disabling the command-local timeout', function()
        start(function()
            scheduler_module.wait_event(scheduler, 'world_unloaded', {
                timeout_ms=false,
                arm=function() end,
                cleanup=function() end,
            })
        end)

        assert.equals(0, #callbacks)
        assert.is_nil(run.outstanding_wait.wall_timeout_ms)
    end)

    it('rejects nonpositive and fractional event timeouts', function()
        local errors = {}
        local owner = coroutine.create(function()
            for _, timeout_ms in ipairs({0, -1, 1.5}) do
                local ok, wait_error = pcall(scheduler_module.wait_event,
                    scheduler, 'paused', {
                        timeout_ms=timeout_ms,
                        arm=function() end,
                        cleanup=function() end,
                    })
                assert.is_false(ok)
                table.insert(errors, wait_error)
            end
        end)
        scheduler_module.bind(scheduler, owner)

        assert.is_true(coroutine.resume(owner))
        assert.equals('dead', coroutine.status(owner))
        assert.equals(3, #errors)
        for _, wait_error in ipairs(errors) do
            assert.matches(
                'event wait timeout must be false or a positive integer',
                wait_error, 1, true)
        end
        assert.equals(0, next_timeout_id)
    end)

    it('times out an event wait with bounded runtime diagnostics', function()
        local cleanup_count = 0
        local wait_ok
        local wait_error
        start(function()
            wait_ok, wait_error = pcall(scheduler_module.wait_event,
                scheduler, 'viewscreen_changed', {
                    description='open controlled screen',
                    timeout_ms=5,
                    arm=function() end,
                    cleanup=function()
                        cleanup_count = cleanup_count + 1
                    end,
                })
        end)
        now = 6
        callbacks[1]()

        assert.is_false(wait_ok)
        assert.matches('automation event wait timed out', wait_error, 1, true)
        assert.matches('operation="open controlled screen"',
            wait_error, 1, true)
        assert.matches('awaited_event="viewscreen_changed"',
            wait_error, 1, true)
        assert.matches('elapsed_ms=6', wait_error, 1, true)
        assert.matches('focus="dwarfmode/Default"', wait_error, 1, true)
        assert.matches('screen="viewscreen_dwarfmodest"',
            wait_error, 1, true)
        assert.equals(1, cleanup_count)
        assert.is_true(completion.ok)
    end)

    it('cancels event listeners exactly once and ignores stale signals',
            function()
        local identity
        local cleanup_count = 0
        local owner = start(function()
            scheduler_module.wait_event(scheduler, 'map_unloaded', {
                timeout_ms=100,
                arm=function(value) identity = value end,
                cleanup=function()
                    cleanup_count = cleanup_count + 1
                end,
            })
        end)
        local stale_callback = callbacks[1]

        assert.is_true(scheduler_module.cancel(scheduler, 'abort proof'))
        assert.is_false(scheduler_module.cancel(scheduler, 'duplicate abort'))
        assert.equals(1, cleanup_count)
        assert.is_nil(active[1])
        assert.is_false(scheduler_module.signal_event(
            scheduler, identity, occurrence('map_unloaded', 1)))
        assert.equals('suspended', coroutine.status(owner))
        stale_callback()
        assert.equals(1, scheduler.stale_callback_count)
        assert.equals(1, cleanup_count)
    end)

    it('ignores a signal after its event wait has completed', function()
        local identity
        local expected = occurrence('paused', 1)
        start(function()
            scheduler_module.wait_event(scheduler, 'paused', {
                arm=function(value)
                    identity = value
                    scheduler_module.signal_event(
                        scheduler, identity, expected)
                end,
                cleanup=function() end,
            })
        end)
        callbacks[1]()

        assert.is_false(scheduler_module.signal_event(
            scheduler, identity, expected))
        assert.is_nil(run.outstanding_wait)
    end)

    it('cleans an event wait once when arming fails', function()
        local cleanup_count = 0
        local wait_ok
        local wait_error
        start(function()
            wait_ok, wait_error = pcall(scheduler_module.wait_event,
                scheduler, 'paused', {
                    arm=function(identity)
                        assert.is_true(scheduler_module.signal_event(
                            scheduler, identity, occurrence('paused', 1)))
                        error('trigger exploded')
                    end,
                    cleanup=function()
                        cleanup_count = cleanup_count + 1
                    end,
                })
        end)

        assert.is_false(wait_ok)
        assert.matches('trigger exploded', wait_error, 1, true)
        assert.equals(1, cleanup_count)
        assert.is_nil(run.outstanding_wait)
        assert.is_nil(active[1])
        assert.is_nil(completion)
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
