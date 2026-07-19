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
    local message = ('automation %s: operation=%q focus=%s screen=%s ' ..
        'elapsed_frames=%d elapsed_ms=%d frame_budget=%d ' ..
        'wall_timeout_ms=%d last_observed=%s')
        :format(kind, wait.operation, diagnostics.focus, diagnostics.screen,
            wait.elapsed_frames, elapsed_ms, wait.frame_budget,
            wait.wall_timeout_ms, observed_text(wait.last_observed))
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
        else
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
        if wait.elapsed_frames >= wait.frame_budget or
                elapsed_ms >= wait.wall_timeout_ms then
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

---Suspends the owner coroutine for one validated wait operation.
---@param scheduler table
---@param wait table
---@return any
local function suspend(scheduler, wait)
    if coroutine.running() ~= scheduler.owner then
        error('dy waits must run inside the active automation suite coroutine', 3)
    end
    if not scheduler.callbacks.is_current() then
        error('automation run no longer owns the scheduler', 3)
    end
    if scheduler.outstanding then
        error('nested automation waits are not supported', 3)
    end

    scheduler.next_wait_id = scheduler.next_wait_id + 1
    wait.id = scheduler.next_wait_id
    wait.state = 'waiting'
    wait.started_ms = scheduler.callbacks.now_ms()
    wait.elapsed_frames = 0
    wait.last_observed = nil
    scheduler.outstanding = wait
    scheduler.run.outstanding_wait = wait
    scheduler.run.suspended = true
    scheduler.run.scheduler_state.operation = wait.operation
    scheduler.run.scheduler_state.elapsed_frames = 0
    local scheduled, schedule_error = schedule_observation(scheduler, wait)
    if not scheduled then
        scheduler.outstanding = nil
        scheduler.run.outstanding_wait = nil
        scheduler.run.suspended = false
        wait.state = 'failed'
        error(schedule_error, 3)
    end

    local ok, value = coroutine.yield(scheduler.yield_token)
    if not ok then error(value, 3) end
    return value
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
    local frame_budget = options.frame_budget or DEFAULT_FRAME_BUDGET
    local wall_timeout_ms = options.timeout_ms or DEFAULT_WALL_TIMEOUT_MS
    assert(type(frame_budget) == 'number' and frame_budget >= 1 and
        frame_budget % 1 == 0, 'frame budget must be a positive integer')
    assert(type(wall_timeout_ms) == 'number' and wall_timeout_ms >= 1,
        'wall timeout must be positive')
    return suspend(scheduler, {
        kind='query',
        operation=description,
        query=query,
        frame_budget=frame_budget,
        wall_timeout_ms=wall_timeout_ms,
    })
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
    cancel_timeout(scheduler, wait.timeout_id)
    wait.timeout_id = nil
    return true
end

return M
