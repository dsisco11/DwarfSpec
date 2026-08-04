-- Native action-timer mutation for run-owned unit-speed behavior.

local M = {}

---Creates an adapter for fastdwarf mode-1-equivalent action acceleration.
---@param dependencies table
---@return table
function M.new(dependencies)
    assert(type(dependencies) == 'table',
        'unit action adapter requires dependencies')
    local set_group_action_timers = dependencies.set_group_action_timers
    assert(type(set_group_action_timers) == 'function',
        'unit action adapter requires set_group_action_timers')
    local all_action_group = dependencies.all_action_group
    assert(all_action_group ~= nil,
        'unit action adapter requires all_action_group')
    local adapter = {}

    ---Sets supported positive action timers for one unit to one tick.
    ---@param unit any
    function adapter:accelerate(unit)
        assert(unit ~= nil, 'unit action adapter requires a unit')
        set_group_action_timers(unit, 1, all_action_group)
    end

    return adapter
end

return M
