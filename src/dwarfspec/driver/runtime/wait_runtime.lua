-- Run-scoped scheduling capability used by verified wait commands.

---@class dwarfspec.WaitRuntime
---@field private _scheduler_module table
---@field private _scheduler table
---@field private _await_event function
---@field private _wait_until function
local WaitRuntime = {}
WaitRuntime.__index = WaitRuntime

---Creates the cohesive wait runtime capability.
---@param options table
---@return dwarfspec.WaitRuntime
function WaitRuntime.new(options)
    assert(type(options) == 'table', 'wait runtime options are required')
    assert(type(options.scheduler_module) == 'table',
        'wait runtime requires a scheduler module')
    for _, name in ipairs({'wait_frames', 'wait_ticks'}) do
        assert(type(options.scheduler_module[name]) == 'function',
            'wait runtime scheduler requires ' .. name)
    end
    assert(type(options.scheduler) == 'table',
        'wait runtime requires a scheduler')
    assert(type(options.await_event) == 'function',
        'wait runtime requires await_event')
    assert(type(options.wait_until) == 'function',
        'wait runtime requires wait_until')
    return setmetatable({_scheduler_module=options.scheduler_module,
        _scheduler=options.scheduler, _await_event=options.await_event,
        _wait_until=options.wait_until}, WaitRuntime)
end

---Copies options and applies the inherited command deadline.
---@param options? table
---@param remaining_ms integer
---@return table
function WaitRuntime:_bounded(options, remaining_ms)
    local bounded = {}
    for name, value in pairs(options or {}) do bounded[name] = value end
    bounded.timeout_ms = remaining_ms
    return bounded
end

---Waits for rendered frames within the inherited command deadline.
---@param count integer
---@param options? table
---@param remaining_ms integer
---@return any
function WaitRuntime:wait_frames(count, options, remaining_ms)
    return self._scheduler_module.wait_frames(self._scheduler, count,
        self:_bounded(options, remaining_ms))
end

---Waits for simulation ticks within the inherited command deadline.
---@param count integer
---@param options? table
---@param remaining_ms integer
---@return any
function WaitRuntime:wait_ticks(count, options, remaining_ms)
    return self._scheduler_module.wait_ticks(self._scheduler, count,
        self:_bounded(options, remaining_ms))
end

---Waits for one native event within the inherited command deadline.
---@param event any
---@param options? table
---@param remaining_ms integer
---@return any
function WaitRuntime:wait_event(event, options, remaining_ms)
    return self._await_event(event, self:_bounded(options, remaining_ms))
end

---Polls a predicate within the inherited command deadline.
---@param description string
---@param query function
---@param options? table
---@param remaining_ms integer
---@return any
function WaitRuntime:wait_until(description, query, options, remaining_ms)
    return self._wait_until(description, query,
        self:_bounded(options, remaining_ms))
end

return WaitRuntime
