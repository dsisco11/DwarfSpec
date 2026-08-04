-- Host adapter for run-owned recurring simulation-tick operations.

local M = {}

---Creates the narrow native scheduling surface for one automation run.
---@param dependencies table
---@return table
function M.new(dependencies)
    assert(type(dependencies) == 'table',
        'recurring operation adapter requires dependencies')
    for _, name in ipairs({
        'schedule_tick', 'cancel_timeout', 'timeout_active',
        'is_run_active', 'report_failure',
    }) do
        assert(type(dependencies[name]) == 'function',
            'recurring operation adapter requires dependency: ' .. name)
    end

    local failure_reported = false

    ---Schedules one callback after one simulation tick.
    ---@param callback function
    ---@return any
    local function schedule(callback)
        assert(type(callback) == 'function',
            'recurring operation callback must be a function')
        if not dependencies.is_run_active() then return nil end
        return dependencies.schedule_tick(1, function()
            if dependencies.is_run_active() then callback() end
        end)
    end

    ---Cancels one native timeout handle.
    ---@param handle any
    ---@return any
    local function cancel(handle)
        if handle == nil then return nil end
        return dependencies.cancel_timeout(handle)
    end

    ---Returns whether one native timeout handle remains scheduled.
    ---@param handle any
    ---@return boolean
    local function is_scheduled(handle)
        return handle ~= nil and
            dependencies.timeout_active(handle) ~= nil or false
    end

    ---Reports the first recurring-operation fault to the active run.
    ---@param message string
    ---@param trace string|nil
    ---@return boolean
    local function report_failure(message, trace)
        assert(type(message) == 'string' and message ~= '',
            'recurring operation failure must be a nonempty string')
        if failure_reported or not dependencies.is_run_active() then
            return false
        end
        failure_reported = true
        dependencies.report_failure(message, trace)
        return true
    end

    return {
        schedule=schedule,
        cancel=cancel,
        is_scheduled=is_scheduled,
        report_failure=report_failure,
    }
end

return M
