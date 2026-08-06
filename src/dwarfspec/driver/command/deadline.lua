-- One absolute monotonic deadline for the complete timed command lifecycle.

local CommandFailureStage = require(
    'dwarfspec.protocol.enums.command_failure_stages')

---@class dwarfspec.CommandDeadline
---@field private _now_ms fun(): number
---@field private _expires_at_ms number
local Deadline = {}
Deadline.__index = Deadline

---@class dwarfspec.driver.command.DeadlineInternals
local Internals = {}

---Validates a finite monotonic timestamp.
---@param value any
---@param label string
---@return number
function Internals.timestamp(value, label)
    assert(type(value) == 'number' and value == value and
        value > -math.huge and value < math.huge,
        label .. ' must be a finite number')
    return value
end

---Validates a positive finite integer timeout.
---@param timeout_ms any
---@return integer
function Internals.timeout(timeout_ms)
    assert(type(timeout_ms) == 'number' and timeout_ms >= 1 and
        timeout_ms % 1 == 0 and timeout_ms < math.huge,
        'command timeout must be a positive finite integer')
    return timeout_ms
end

---Creates an absolute deadline by sampling the injected clock exactly once.
---@param now_ms fun(): number
---@param timeout_ms integer
---@return dwarfspec.CommandDeadline
function Deadline.new(now_ms, timeout_ms)
    assert(type(now_ms) == 'function',
        'command deadline requires a monotonic clock callback')
    local started_at_ms = Internals.timestamp(now_ms(), 'monotonic clock')
    return setmetatable({
        _now_ms=now_ms,
        _expires_at_ms=started_at_ms + Internals.timeout(timeout_ms),
    }, Deadline)
end

---Returns the immutable absolute expiration timestamp.
---@return number
function Deadline:expires_at_ms()
    return self._expires_at_ms
end

---Returns remaining whole milliseconds, rounded up to avoid early expiry.
---@return integer
function Deadline:remaining_ms()
    local now = Internals.timestamp(self._now_ms(), 'monotonic clock')
    return math.max(0, math.ceil(self._expires_at_ms - now))
end

---Returns whether the sampled monotonic time reached or passed the deadline.
---@return boolean
function Deadline:is_expired()
    local now = Internals.timestamp(self._now_ms(), 'monotonic clock')
    return now >= self._expires_at_ms
end

---Classifies a completed synchronous execution using its return timestamp.
---@param evidence? table
---@return boolean completed_in_time
---@return table|nil timeout_evidence
function Deadline:check_execution_return(evidence)
    local returned_at_ms = Internals.timestamp(
        self._now_ms(), 'monotonic clock')
    if returned_at_ms < self._expires_at_ms then return true, nil end
    return false, {
        kind='timeout',
        failure_stage=CommandFailureStage.EXECUTION,
        deadline_ms=self._expires_at_ms,
        returned_at_ms=returned_at_ms,
        evidence=evidence,
    }
end

return Deadline
