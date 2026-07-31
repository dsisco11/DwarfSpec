-- Single-owner coroutine scheduler for live frame-dependent automation.

local M = {}

local DEFAULT_FRAME_BUDGET = 300
local DEFAULT_WALL_TIMEOUT_MS = 10000

---Returns a stable compact representation of one observed value.
---@param value any
---@return string
local function observed_text(value)
    local value_type = type(value)
    if value_type == 'nil' then return 'nil' end
    if value_type == 'string' then return string.format('%q', value) end
    if value_type == 'number' or value_type == 'boolean' then
        return tostring(value)
    end
    return '<' .. value_type .. '>'
end

---Returns diagnostic context without allowing diagnostics to break a wait.
---@param scheduler table
---@return table
local function diagnostic_context(scheduler)
    local ok, diagnostics = pcall(scheduler.callbacks.diagnostics)
    if not ok or type(diagnostics) ~= 'table' then
        return {focus='<unavailable>', screen='<unavailable>'}
    end
    return {
        focus=observed_text(diagnostics.focus),
        screen=observed_text(diagnostics.screen),
    }
end

---Builds an actionable operational error for an outstanding wait.
---@param scheduler table
---@param wait table
---@param kind string
---@param cause any|nil
---@return string
local function wait_error(scheduler, wait, kind, cause)
    local diagnostics = diagnostic_context(scheduler)
    local elapsed_ms = scheduler.callbacks.now_ms() - wait.started_ms
    local frame_budget = wait.frame_budget == nil and
        'unlimited' or tostring(wait.frame_budget)
    local wall_timeout_ms = wait.wall_timeout_ms == nil and
        'unlimited' or tostring(wait.wall_timeout_ms)
    local awaited_event = wait.awaited_event == nil and
        'none' or observed_text(wait.awaited_event)
    local message = ('automation %s: operation=%q focus=%s screen=%s ' ..
        'elapsed_frames=%d elapsed_ms=%d frame_budget=%s ' ..
        'wall_timeout_ms=%s awaited_event=%s last_observed=%s')
        :format(kind, wait.operation, diagnostics.focus, diagnostics.screen,
            wait.elapsed_frames, elapsed_ms, frame_budget,
            wall_timeout_ms, awaited_event,
            observed_text(wait.last_observed))
    if cause ~= nil then message = message .. ' cause=' .. tostring(cause) end
    return message
end

---Cancels one DFHack timeout if it is still registered.
---@param scheduler table
---@param timeout_id any
local function cancel_timeout(scheduler, timeout_id)
    if timeout_id ~= nil then
        scheduler.callbacks.cancel_timeout(timeout_id)
    end
end

---Cancels every callback owned by one wait.
---@param scheduler table
---@param wait table
local function cancel_wait_timeouts(scheduler, wait)
    cancel_timeout(scheduler, wait.timeout_id)
    wait.timeout_id = nil
    cancel_timeout(scheduler, wait.tick_timeout_id)
    wait.tick_timeout_id = nil
end

---Invokes one wait-owned cleanup callback at most once.
---@param wait table
---@return boolean, any
local function cleanup_wait(wait)
    if wait.cleanup_done then return true end
    wait.cleanup_done = true
    if wait.cleanup == nil then return true end
    return pcall(wait.cleanup)
end

---Records one callback that no longer owns the active wait.
---@param scheduler table
local function reject_stale_callback(scheduler)
    scheduler.stale_callback_count = scheduler.stale_callback_count + 1
    scheduler.run.scheduler_state.stale_callback_count =
        scheduler.stale_callback_count
end

---Resumes the sole owner coroutine after an operation completes.
---@param scheduler table
---@param wait table
---@param ok boolean
---@param value any
local function resume_owner(scheduler, wait, ok, value)
    if scheduler.outstanding ~= wait or
            not scheduler.callbacks.is_current() then
        reject_stale_callback(scheduler)
        return
    end
    scheduler.outstanding = nil
    scheduler.run.outstanding_wait = nil
    scheduler.run.suspended = false
    wait.state = ok and 'completed' or 'failed'

    local resumed, yielded = coroutine.resume(scheduler.owner, ok, value)
    if not resumed then
        scheduler.callbacks.on_complete(false, yielded)
        return
    end
    if coroutine.status(scheduler.owner) == 'dead' then
        scheduler.callbacks.on_complete(true)
        return
    end
    if yielded ~= scheduler.yield_token or not scheduler.outstanding then
        scheduler.callbacks.on_complete(false,
            'automation suite yielded outside the owned scheduler')
    end
end

---Schedules a safe frame-boundary pump for one event wait.
---@param scheduler table
---@param wait table
---@return boolean, string|nil
local function schedule_event_pump(scheduler, wait)
    if wait.timeout_id ~= nil then return true end
    local timeout_id
    timeout_id = scheduler.callbacks.schedule_timeout(1, function()
        if scheduler.outstanding ~= wait or
                not scheduler.callbacks.is_current() then
            reject_stale_callback(scheduler)
            return
        end
        if wait.timeout_id ~= timeout_id then
            reject_stale_callback(scheduler)
            return
        end
        wait.timeout_id = nil
        wait.elapsed_frames = wait.elapsed_frames + 1
        scheduler.run.scheduler_state.elapsed_frames = wait.elapsed_frames

        if wait.signaled then
            local cleanup_ok, cleanup_error = cleanup_wait(wait)
            if not cleanup_ok then
                resume_owner(scheduler, wait, false,
                    wait_error(scheduler, wait, 'listener cleanup failed',
                        cleanup_error))
                return
            end
            resume_owner(scheduler, wait, true, wait.occurrence)
            return
        end

        local elapsed_ms = scheduler.callbacks.now_ms() - wait.started_ms
        if wait.wall_timeout_ms ~= nil and
                elapsed_ms >= wait.wall_timeout_ms then
            local cleanup_ok, cleanup_error = cleanup_wait(wait)
            if not cleanup_ok then
                resume_owner(scheduler, wait, false,
                    wait_error(scheduler, wait, 'listener cleanup failed',
                        cleanup_error))
                return
            end
            resume_owner(scheduler, wait, false,
                wait_error(scheduler, wait, 'event wait timed out'))
            return
        end
        schedule_event_pump(scheduler, wait)
    end)
    if timeout_id == nil then
        return false, wait_error(scheduler, wait, 'scheduler error',
            'DFHack rejected the event pump timeout')
    end
    wait.timeout_id = timeout_id
    return true
end

---Schedules the next raw-frame observation for one wait.
---@param scheduler table
---@param wait table
---@return boolean, string|nil
local function schedule_observation(scheduler, wait)
    local timeout_id
    timeout_id = scheduler.callbacks.schedule_timeout(1, function()
        if scheduler.outstanding ~= wait or
                not scheduler.callbacks.is_current() then
            reject_stale_callback(scheduler)
            return
        end
        if wait.timeout_id ~= timeout_id then
            reject_stale_callback(scheduler)
            return
        end
        wait.timeout_id = nil
        wait.elapsed_frames = wait.elapsed_frames + 1
        scheduler.run.scheduler_state.elapsed_frames = wait.elapsed_frames

        local done = false
        local result
        if wait.kind == 'frames' then
            wait.last_observed = wait.elapsed_frames
            done = wait.elapsed_frames >= wait.target_frames
            result = wait.elapsed_frames
        elseif wait.kind == 'query' then
            local query_ok, observed = pcall(wait.query)
            if not query_ok then
                resume_owner(scheduler, wait, false,
                    wait_error(scheduler, wait, 'interaction error', observed))
                return
            end
            wait.last_observed = observed
            done = not not observed
            result = observed
        end

        if done then
            resume_owner(scheduler, wait, true, result)
            return
        end

        local elapsed_ms = scheduler.callbacks.now_ms() - wait.started_ms
        if (wait.frame_budget ~= nil and
                wait.elapsed_frames >= wait.frame_budget) or
                (wait.wall_timeout_ms ~= nil and
                    elapsed_ms >= wait.wall_timeout_ms) then
            cancel_timeout(scheduler, wait.tick_timeout_id)
            wait.tick_timeout_id = nil
            resume_owner(scheduler, wait, false,
                wait_error(scheduler, wait, 'wait timed out'))
            return
        end
        schedule_observation(scheduler, wait)
    end)
    if timeout_id == nil then
        local message = wait_error(scheduler, wait, 'scheduler error',
            'DFHack rejected the frame timeout')
        if coroutine.running() == scheduler.owner then
            return false, message
        end
        resume_owner(scheduler, wait, false, message)
        return false, message
    end
    wait.timeout_id = timeout_id
    return true
end

---Schedules completion after an exact number of unpaused simulation ticks.
---@param scheduler table
---@param wait table
---@return boolean, string|nil
local function schedule_tick_completion(scheduler, wait)
    local timeout_id
    timeout_id = scheduler.callbacks.schedule_tick_timeout(
        wait.target_ticks, function()
            if scheduler.outstanding ~= wait or
                    not scheduler.callbacks.is_current() then
                reject_stale_callback(scheduler)
                return
            end
            if wait.tick_timeout_id ~= timeout_id then
                reject_stale_callback(scheduler)
                return
            end
            wait.tick_timeout_id = nil
            wait.last_observed = wait.target_ticks
            cancel_timeout(scheduler, wait.timeout_id)
            wait.timeout_id = nil
            resume_owner(scheduler, wait, true, wait.target_ticks)
        end)
    if timeout_id == nil then
        return false, wait_error(scheduler, wait, 'scheduler error',
            'DFHack rejected the simulation-tick timeout')
    end
    wait.tick_timeout_id = timeout_id
    return true
end

---Prepares one validated wait before its callbacks are armed.
---@param scheduler table
---@param wait table
local function begin_wait(scheduler, wait)
    if coroutine.running() ~= scheduler.owner then
        error('ds waits must run inside the active automation suite coroutine', 3)
    end
    if not scheduler.callbacks.is_current() then
        error('automation run no longer owns the scheduler', 3)
    end
    if scheduler.outstanding then
        error('nested automation waits are not supported', 3)
    end

    scheduler.next_wait_id = scheduler.next_wait_id + 1
    wait.id = scheduler.next_wait_id
    if wait.kind == 'event' then wait.identity = {} end
    wait.state = 'waiting'
    wait.started_ms = scheduler.callbacks.now_ms()
    wait.elapsed_frames = 0
    wait.last_observed = nil
    scheduler.outstanding = wait
    scheduler.run.outstanding_wait = wait
    scheduler.run.suspended = true
    scheduler.run.scheduler_state.operation = wait.operation
    scheduler.run.scheduler_state.elapsed_frames = 0
end

---Yields the owner until one prepared wait resumes it.
---@param scheduler table
---@return any
local function yield_wait(scheduler)
    local ok, value = coroutine.yield(scheduler.yield_token)
    if not ok then error(value, 3) end
    return value
end

---Suspends the owner coroutine for one validated wait operation.
---@param scheduler table
---@param wait table
---@return any
local function suspend(scheduler, wait)
    begin_wait(scheduler, wait)
    if wait.kind == 'ticks' then
        local tick_scheduled, tick_error =
            schedule_tick_completion(scheduler, wait)
        if not tick_scheduled then
            scheduler.outstanding = nil
            scheduler.run.outstanding_wait = nil
            scheduler.run.suspended = false
            wait.state = 'failed'
            error(tick_error, 3)
        end
    end
    local scheduled, schedule_error = schedule_observation(scheduler, wait)
    if not scheduled then
        cancel_wait_timeouts(scheduler, wait)
        scheduler.outstanding = nil
        scheduler.run.outstanding_wait = nil
        scheduler.run.suspended = false
        wait.state = 'failed'
        error(schedule_error, 3)
    end

    return yield_wait(scheduler)
end

---Creates an unbound scheduler for one generation-owned automation run.
---@param run table
---@param callbacks table
---@return table
function M.new(run, callbacks)
    assert(type(callbacks.is_current) == 'function',
        'scheduler requires an ownership callback')
    assert(type(callbacks.schedule_timeout) == 'function',
        'scheduler requires a timeout callback')
    assert(type(callbacks.schedule_tick_timeout) == 'function',
        'scheduler requires a simulation-tick timeout callback')
    assert(type(callbacks.cancel_timeout) == 'function',
        'scheduler requires a timeout cancellation callback')
    assert(type(callbacks.now_ms) == 'function',
        'scheduler requires a monotonic clock callback')
    assert(type(callbacks.diagnostics) == 'function',
        'scheduler requires a diagnostics callback')
    assert(type(callbacks.on_complete) == 'function',
        'scheduler requires a completion callback')
    run.scheduler_state = {
        operation=nil,
        elapsed_frames=0,
        stale_callback_count=0,
        cancellation_reason=nil,
    }
    return {
        run=run,
        callbacks=callbacks,
        owner=nil,
        outstanding=nil,
        yield_token={},
        next_wait_id=0,
        stale_callback_count=0,
    }
end

---Binds the scheduler to the only coroutine it may suspend or resume.
---@param scheduler table
---@param owner thread
function M.bind(scheduler, owner)
    assert(type(owner) == 'thread', 'scheduler owner must be a coroutine')
    assert(scheduler.owner == nil, 'scheduler already has an owner')
    scheduler.owner = owner
end

---Returns whether a suspended value belongs to this scheduler.
---@param scheduler table
---@param yielded any
---@return boolean
function M.owns_yield(scheduler, yielded)
    return yielded == scheduler.yield_token and scheduler.outstanding ~= nil
end

---Waits for an exact number of actual DFHack raw-frame callbacks.
---@param scheduler table
---@param count integer
---@param options table|nil
---@return integer
function M.wait_frames(scheduler, count, options)
    options = options or {}
    assert(type(count) == 'number' and count >= 1 and count % 1 == 0,
        'frame count must be a positive integer')
    local wall_timeout_ms = options.timeout_ms or DEFAULT_WALL_TIMEOUT_MS
    assert(type(wall_timeout_ms) == 'number' and wall_timeout_ms >= 1,
        'wall timeout must be positive')
    return suspend(scheduler, {
        kind='frames',
        operation=options.description or ('wait_frames(' .. count .. ')'),
        target_frames=count,
        frame_budget=count,
        wall_timeout_ms=wall_timeout_ms,
    })
end

---Waits for an exact number of unpaused Dwarf Fortress simulation ticks.
---@param scheduler table
---@param count integer
---@param options table|nil
---@return integer
function M.wait_ticks(scheduler, count, options)
    options = options or {}
    assert(type(count) == 'number' and count >= 1 and count % 1 == 0,
        'simulation tick count must be a positive integer')
    local wall_timeout_ms = options.timeout_ms or DEFAULT_WALL_TIMEOUT_MS
    assert(type(wall_timeout_ms) == 'number' and wall_timeout_ms >= 1,
        'wall timeout must be positive')
    return suspend(scheduler, {
        kind='ticks',
        operation=options.description or ('wait_ticks(' .. count .. ')'),
        target_ticks=count,
        wall_timeout_ms=wall_timeout_ms,
    })
end

---Polls a read-only query between frames until it returns a truthy value.
---@param scheduler table
---@param description string
---@param query function
---@param options table|nil
---@return any
function M.wait_until(scheduler, description, query, options)
    options = options or {}
    assert(type(description) == 'string' and description ~= '',
        'wait description must be a nonempty string')
    assert(type(query) == 'function', 'wait query must be a function')
    local frame_budget = options.frame_budget
    if frame_budget == nil then
        frame_budget = DEFAULT_FRAME_BUDGET
    elseif frame_budget == false then
        frame_budget = nil
    end
    local wall_timeout_ms = options.timeout_ms
    if wall_timeout_ms == nil then
        wall_timeout_ms = DEFAULT_WALL_TIMEOUT_MS
    elseif wall_timeout_ms == false then
        wall_timeout_ms = nil
    end
    assert(frame_budget == nil or
            (type(frame_budget) == 'number' and frame_budget >= 1 and
                frame_budget % 1 == 0),
        'frame budget must be false or a positive integer')
    assert(wall_timeout_ms == nil or
            (type(wall_timeout_ms) == 'number' and wall_timeout_ms >= 1),
        'wall timeout must be false or positive')
    return suspend(scheduler, {
        kind='query',
        operation=description,
        query=query,
        frame_budget=frame_budget,
        wall_timeout_ms=wall_timeout_ms,
    })
end

---Waits for one externally signaled event occurrence at a safe frame boundary.
---@param scheduler table
---@param awaited_event string
---@param options table
---@return table
function M.wait_event(scheduler, awaited_event, options)
    options = options or {}
    assert(type(awaited_event) == 'string' and awaited_event ~= '',
        'awaited event must be a nonempty string')
    local operation = options.description or
        ('await event ' .. awaited_event)
    assert(type(operation) == 'string' and operation ~= '',
        'event wait description must be a nonempty string')
    local wall_timeout_ms = options.timeout_ms
    if wall_timeout_ms == false then wall_timeout_ms = nil end
    assert(wall_timeout_ms == nil or
            (type(wall_timeout_ms) == 'number' and wall_timeout_ms >= 1 and
                wall_timeout_ms % 1 == 0),
        'event wait timeout must be false or a positive integer')
    assert(type(options.arm) == 'function',
        'event wait requires an arm callback')
    assert(type(options.cleanup) == 'function',
        'event wait requires a listener cleanup callback')

    local wait = {
        kind='event',
        operation=operation,
        awaited_event=awaited_event,
        wall_timeout_ms=wall_timeout_ms,
        cleanup=options.cleanup,
        cleanup_done=false,
        signaled=false,
    }
    begin_wait(scheduler, wait)

    local armed, arm_error = pcall(options.arm, wait.identity)
    if not armed then
        cancel_wait_timeouts(scheduler, wait)
        scheduler.outstanding = nil
        scheduler.run.outstanding_wait = nil
        scheduler.run.suspended = false
        wait.state = 'failed'
        local cleanup_ok, cleanup_error = cleanup_wait(wait)
        if not cleanup_ok then
            error(tostring(arm_error) .. '\nlistener cleanup failed: ' ..
                tostring(cleanup_error), 3)
        end
        error(arm_error, 3)
    end

    if wait.signaled or wait.wall_timeout_ms ~= nil then
        local scheduled, schedule_error = schedule_event_pump(scheduler, wait)
        if not scheduled then
            scheduler.outstanding = nil
            scheduler.run.outstanding_wait = nil
            scheduler.run.suspended = false
            wait.state = 'failed'
            cleanup_wait(wait)
            error(schedule_error, 3)
        end
    end
    return yield_wait(scheduler)
end

---Queues one immutable occurrence for the matching outstanding event wait.
---@param scheduler table
---@param wait_identity table
---@param occurrence table
---@return boolean
function M.signal_event(scheduler, wait_identity, occurrence)
    local wait = scheduler.outstanding
    if not wait or wait.kind ~= 'event' or
            wait.identity ~= wait_identity or wait.state ~= 'waiting' or
            wait.signaled or not scheduler.callbacks.is_current() then
        return false
    end
    assert(type(occurrence) == 'table',
        'event occurrence must be an immutable table')
    if occurrence.event ~= wait.awaited_event then return false end

    wait.signaled = true
    wait.occurrence = occurrence
    wait.last_observed = occurrence
    local scheduled, schedule_error =
        schedule_event_pump(scheduler, wait)
    if not scheduled then
        wait.signaled = false
        wait.occurrence = nil
        wait.last_observed = nil
        wait.signal_error = schedule_error
        return false
    end
    return true
end

---Cancels the outstanding wait without resuming the discarded owner.
---@param scheduler table
---@param reason string
---@return boolean
function M.cancel(scheduler, reason)
    local wait = scheduler.outstanding
    scheduler.run.scheduler_state.cancellation_reason = reason
    if not wait then return false end
    scheduler.outstanding = nil
    scheduler.run.outstanding_wait = nil
    scheduler.run.suspended = false
    wait.state = 'cancelled'
    wait.cancellation_reason = reason
    cancel_wait_timeouts(scheduler, wait)
    local cleanup_ok, cleanup_error = cleanup_wait(wait)
    if not cleanup_ok then wait.cleanup_error = cleanup_error end
    return true
end

return M
