-- Deterministic builders for multi-project automation service unit tests.

local ResultPolicy = require('dwarfspec.automation.result_policies')
local RunState = require('dwarfspec.automation.run_states')

local M = {}

---Copies a flat record and applies caller overrides.
---@param defaults table
---@param overrides table|nil
---@return table
local function record(defaults, overrides)
    local result = {}
    for key, value in pairs(defaults) do result[key] = value end
    for key, value in pairs(overrides or {}) do result[key] = value end
    return result
end

---Creates deterministic typed identifiers for one test namespace.
---@param namespace string
---@param first integer|nil
---@return table
function M.identifiers(namespace, first)
    assert(type(namespace) == 'string' and namespace ~= '',
        'identifier namespace must be a nonempty string')
    local value = first or 1
    local identifiers = {}

    ---Returns the next deterministic identifier of the requested kind.
    ---@param kind string
    ---@return string
    function identifiers.next(kind)
        assert(type(kind) == 'string' and kind ~= '',
            'identifier kind must be a nonempty string')
        local identifier = ('%s-%s-%d'):format(kind, namespace, value)
        value = value + 1
        return identifier
    end

    return identifiers
end

---Creates a manually advanced monotonic fake clock.
---@param initial_ms integer|nil
---@return table
function M.clock(initial_ms)
    local current_ms = initial_ms or 0
    local clock = {}

    ---Returns the current fake monotonic time.
    ---@return integer
    function clock.now_ms()
        return current_ms
    end

    ---Advances fake monotonic time and returns the new value.
    ---@param elapsed_ms integer
    ---@return integer
    function clock.advance(elapsed_ms)
        assert(type(elapsed_ms) == 'number' and elapsed_ms >= 0 and
            elapsed_ms % 1 == 0, 'elapsed time must be a nonnegative integer')
        current_ms = current_ms + elapsed_ms
        return current_ms
    end

    return clock
end

---Creates a deterministic callback scheduler driven by a fake clock.
---@param clock table
---@return table
function M.scheduler(clock)
    assert(type(clock) == 'table' and type(clock.now_ms) == 'function',
        'scheduler requires a fake clock')
    local next_id = 1
    local tasks = {}
    local scheduler = {}

    ---Schedules a callback after the requested fake delay.
    ---@param delay_ms integer
    ---@param callback function
    ---@return integer
    function scheduler.schedule(delay_ms, callback)
        assert(type(delay_ms) == 'number' and delay_ms >= 0 and
            delay_ms % 1 == 0, 'delay must be a nonnegative integer')
        assert(type(callback) == 'function',
            'scheduled callback must be a function')
        local id = next_id
        next_id = next_id + 1
        tasks[id] = {
            id=id,
            due_ms=clock.now_ms() + delay_ms,
            callback=callback,
        }
        return id
    end

    ---Cancels one pending callback by identifier.
    ---@param id integer
    ---@return boolean
    function scheduler.cancel(id)
        if tasks[id] == nil then return false end
        tasks[id] = nil
        return true
    end

    ---Returns the number of pending callbacks.
    ---@return integer
    function scheduler.pending_count()
        local count = 0
        for _ in pairs(tasks) do count = count + 1 end
        return count
    end

    ---Runs the earliest due callback and returns its identifier.
    ---@return integer|nil
    function scheduler.run_next()
        local selected
        for _, task in pairs(tasks) do
            if task.due_ms <= clock.now_ms() and
                    (selected == nil or task.due_ms < selected.due_ms or
                     (task.due_ms == selected.due_ms and
                      task.id < selected.id)) then
                selected = task
            end
        end
        if selected == nil then return nil end
        tasks[selected.id] = nil
        selected.callback()
        return selected.id
    end

    return scheduler
end

---Builds one independent project record.
---@param overrides table|nil
---@return table
function M.project(overrides)
    return record({
        project_id='project-fixture-1',
        normalized_project_root='tests/framework/service_project_alpha',
        display_name='Service Project Alpha',
        normalized_configuration={},
        result_path='tests/framework/service_project_alpha/tests/' ..
            '.test-results/dwarfspec/results.json',
        result_policy=ResultPolicy.FILE,
        client_compatibility={protocol=2, package_version='0.1.2'},
        registered_at_ms=0,
        outstanding_run_id=nil,
    }, overrides)
end

---Builds one independent run record.
---@param overrides table|nil
---@return table
function M.run(overrides)
    return record({
        service_instance_id='service-fixture-1',
        project_id='project-fixture-1',
        run_id='run-fixture-1',
        generation=1,
        state=RunState.QUEUED,
        terminal=false,
        sequence=0,
        events={},
        submitted_at_ms=0,
        activated_at_ms=nil,
        finished_at_ms=nil,
        cleanup_confirmed=false,
    }, overrides)
end

---Builds one independent service registry.
---@param overrides table|nil
---@return table
function M.registry(overrides)
    return record({
        protocol_version=2,
        service_instance_id='service-fixture-1',
        package_root='D:/package',
        package_version='0.1.2',
        generation=0,
        projects={},
        runs={},
        queue={},
        active_run_id=nil,
        quarantine={active=false, reason=nil},
        latest_terminal_results={},
    }, overrides)
end

return M
