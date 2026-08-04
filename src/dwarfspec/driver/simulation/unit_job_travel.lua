-- Guarded fastdwarf-equivalent travel to a unit's current job destination.

local M = {}

---Requires one callable job-travel dependency.
---@param dependencies table
---@param name string
---@return function
local function require_function(dependencies, name)
    local value = dependencies[name]
    assert(type(value) == 'function',
        'unit job travel requires dependency: ' .. name)
    return value
end

---Returns whether two coordinate values are equal.
---@param left table
---@param right table
---@return boolean
local function positions_equal(left, right)
    return left.x == right.x and left.y == right.y and left.z == right.z
end

---Creates guarded job-destination travel behavior.
---@param dependencies table
---@return table
function M.new(dependencies)
    assert(type(dependencies) == 'table',
        'unit job travel requires dependencies')
    local resolve_unit = require_function(dependencies, 'resolve_unit')
    local is_valid_position = require_function(dependencies, 'is_valid_position')
    local can_walk_between = require_function(dependencies, 'can_walk_between')
    local is_tile_visible = require_function(dependencies, 'is_tile_visible')
    local resize_vector = require_function(dependencies, 'resize_vector')
    local dragger_relationship = assert(dependencies.dragger_relationship,
        'unit job travel requires dragger relationship')
    local draggee_relationship = assert(dependencies.draggee_relationship,
        'unit job travel requires draggee relationship')
    local position_controller = assert(dependencies.position_controller,
        'unit job travel requires position controller')
    local travel = {}

    ---Attempts one guarded teleport to the current job destination.
    ---@param unit_id integer
    ---@return boolean
    function travel:attempt(unit_id)
        local unit = resolve_unit(unit_id)
        if unit == nil or
                unit.relationship_ids[dragger_relationship] ~= -1 or
                unit.relationship_ids[draggee_relationship] ~= -1 or
                unit.following ~= 0 or unit.counters.unconscious ~= 0 or
                unit.job.current_job == nil then
            return false
        end
        local source = unit.pos
        local destination = unit.path.dest
        if not is_valid_position(source) or not is_valid_position(destination) or
                positions_equal(source, destination) or
                not can_walk_between(source, destination) or
                not is_tile_visible(destination) then
            return false
        end
        if not position_controller:move(unit_id, destination) then return false end
        resize_vector(unit.path.path.x, 0)
        resize_vector(unit.path.path.y, 0)
        resize_vector(unit.path.path.z, 0)
        return true
    end

    return travel
end

return M
