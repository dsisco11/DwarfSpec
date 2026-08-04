-- Run-owned recurring-operation controller for driver simulations.

local M = {}

---Requires one callable dependency.
---@param owner table
---@param name string
---@return function
local function require_function(owner, name)
    local value = owner and owner[name]
    assert(type(value) == 'function',
        'recurring operation requires dependency: ' .. name)
    return value
end

---Creates one inactive recurring-operation controller.
---@param dependencies table
---@return table
function M.new(dependencies)
    assert(type(dependencies) == 'table',
        'recurring operation requires dependencies')
    local schedule = require_function(dependencies, 'schedule')
    local cancel = require_function(dependencies, 'cancel')
    local is_scheduled = require_function(dependencies, 'is_scheduled')
    local report_failure = require_function(dependencies, 'report_failure')
    local register_cleanup = require_function(dependencies, 'register_cleanup')

    local controller = {
        active=false,
        generation=0,
        handle=nil,
        ownership_token=nil,
        retained_ids={},
        callback=nil,
        fault=nil,
        failure_reported=false,
    }

    ---Clears state that must not survive a stopped operation.
    local function clear_owned_state()
        controller.callback = nil
        controller.retained_ids = {}
        controller.ownership_token = nil
    end

    ---Stops owned work and verifies that its timeout is absent.
    ---@return boolean
    local function stop()
        controller.active = false
        controller.generation = controller.generation + 1
        local handle = controller.handle
        if handle ~= nil then
            cancel(handle)
            if is_scheduled(handle) then
                error('recurring operation callback remains scheduled', 2)
            end
            controller.handle = nil
        end
        clear_owned_state()
        return handle ~= nil
    end

    ---Reports one fault, after making later callbacks inert.
    ---@param failure any
    local function fail(failure)
        local trace = tostring(failure)
        controller.fault = trace
        controller.active = false
        controller.generation = controller.generation + 1
        controller.handle = nil
        clear_owned_state()
        if not controller.failure_reported then
            controller.failure_reported = true
            report_failure('recurring operation callback failed', trace)
        end
    end

    local schedule_next

    ---Runs one owned callback and arms its successor on success.
    ---@param generation integer
    ---@param token table
    ---@param expected_handle any
    local function dispatch(generation, token, expected_handle)
        if not controller.active or
                controller.generation ~= generation or
                controller.ownership_token ~= token or
                controller.handle ~= expected_handle then
            return
        end
        controller.handle = nil
        local ok, failure = xpcall(controller.callback, debug.traceback)
        if not ok then
            fail(failure)
            return
        end
        schedule_next(generation, token)
    end

    ---Schedules the next owned tick callback.
    ---@param generation integer
    ---@param token table
    function schedule_next(generation, token)
        if not controller.active or
                controller.generation ~= generation or
                controller.ownership_token ~= token then
            return false
        end
        local handle
        handle = schedule(function()
            dispatch(generation, token, handle)
        end)
        if handle == nil then
            fail('DFHack rejected the recurring simulation-tick callback')
            return false
        end
        controller.handle = handle
        return true
    end

    ---Starts recurring work after registering its cleanup ownership.
    ---@param callback function
    ---@param retained_ids integer[]|nil
    function controller:start(callback, retained_ids)
        assert(type(callback) == 'function',
            'recurring operation callback must be a function')
        assert(not self.active and self.ownership_token == nil and
                self.handle == nil,
            'recurring operation is already active')
        self.generation = self.generation + 1
        local generation = self.generation
        local token = {}
        self.active = true
        self.ownership_token = token
        self.callback = callback
        self.retained_ids = {}
        for index, id in ipairs(retained_ids or {}) do
            self.retained_ids[index] = id
        end
        self.fault = nil
        self.failure_reported = false
        register_cleanup('unit speed recurring operation', function()
            stop()
        end)
        if not schedule_next(generation, token) then
            error(self.fault, 2)
        end
    end

    ---Stops recurring work idempotently.
    ---@return boolean
    function controller:stop()
        return stop()
    end

    ---Returns whether the controller or its native callback is owned.
    ---@return boolean
    function controller:is_active()
        return self.active or self.ownership_token ~= nil or
            self.handle ~= nil or
            self.handle ~= nil and is_scheduled(self.handle)
    end

    ---Returns read-only cleanup state for authoritative verification.
    ---@return table
    function controller:cleanup_state()
        local scheduled = self.handle ~= nil and
            is_scheduled(self.handle) or false
        return {
            unit_speed_active=self.active or
                self.ownership_token ~= nil or self.handle ~= nil or scheduled,
            callback_scheduled=scheduled,
            ownership_active=self.ownership_token ~= nil,
            retained_id_count=#self.retained_ids,
            fault=self.fault,
        }
    end

    return controller
end

return M
