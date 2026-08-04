-- Native teleport safety and rollback verification for DwarfSpec-owned moves.

local M = {}

---Returns a copied coordinate value.
---@param position table
---@return table
local function copy_position(position)
    return {x=position.x, y=position.y, z=position.z}
end

---Returns whether two coordinate values are equal.
---@param left table
---@param right table
---@return boolean
local function positions_equal(left, right)
    return left.x == right.x and left.y == right.y and left.z == right.z
end

---Requires one callable native dependency.
---@param dependencies table
---@param name string
---@return function
local function require_function(dependencies, name)
    local value = dependencies[name]
    assert(type(value) == 'function',
        'unit position adapter requires dependency: ' .. name)
    return value
end

---Creates a native adapter for safely reversible unit teleportation.
---@param dependencies table
---@return table
function M.new(dependencies)
    assert(type(dependencies) == 'table',
        'unit position adapter requires dependencies')
    local is_map_loaded = require_function(dependencies, 'is_map_loaded')
    local is_valid_position = require_function(dependencies, 'is_valid_position')
    local resolve_unit = require_function(dependencies, 'resolve_unit')
    local get_occupancy = require_function(dependencies, 'get_occupancy')
    local teleport = require_function(dependencies, 'teleport')
    local is_projectile = require_function(dependencies, 'is_projectile')
    local has_rider = require_function(dependencies, 'has_rider')
    local is_rider = require_function(dependencies, 'is_rider')
    local adapter = {}

    ---Resolves one stable unit identifier at the point of use.
    ---@param unit_id integer
    ---@return any
    function adapter:resolve(unit_id)
        return resolve_unit(unit_id)
    end

    ---Returns a copied valid loaded-map coordinate.
    ---@param position table
    ---@return table|nil
    function adapter:normalize_position(position)
        if type(position) ~= 'table' or
                type(position.x) ~= 'number' or position.x % 1 ~= 0 or
                type(position.y) ~= 'number' or position.y % 1 ~= 0 or
                type(position.z) ~= 'number' or position.z % 1 ~= 0 then
            return nil
        end
        local copied = copy_position(position)
        if not is_map_loaded() or not is_valid_position(copied) then return nil end
        return copied
    end

    ---Captures rollback state immediately before an attempted first move.
    ---@param unit any
    ---@return table|nil
    function adapter:capture_baseline(unit)
        if not is_map_loaded() or unit == nil or
                not is_valid_position(unit.pos) or is_projectile(unit) or
                has_rider(unit) or is_rider(unit) then
            return nil
        end
        local occupancy = get_occupancy(unit.pos)
        if occupancy == nil then return nil end
        local on_ground = unit.flags1.on_ground == true
        if on_ground and occupancy.unit_grounded ~= true or
                not on_ground and occupancy.unit ~= true then
            return nil
        end
        return {
            position=copy_position(unit.pos),
            idle_area=copy_position(unit.idle_area),
            on_ground=on_ground,
            occupancy={
                unit=occupancy.unit == true,
                unit_grounded=occupancy.unit_grounded == true,
            },
        }
    end

    ---Teleports one unit only when the native side effects remain reversible.
    ---@param unit any
    ---@param destination table
    ---@return boolean, table|nil
    function adapter:teleport(unit, destination)
        if not is_map_loaded() or unit == nil or
                not is_valid_position(unit.pos) or
                not is_valid_position(destination) or
                positions_equal(unit.pos, destination) or
                is_projectile(unit) or has_rider(unit) or is_rider(unit) then
            return false, nil
        end
        local source = get_occupancy(unit.pos)
        local target = get_occupancy(destination)
        if source == nil or target == nil then return false, nil end
        local on_ground = unit.flags1.on_ground == true
        if on_ground and source.unit_grounded ~= true or
                not on_ground and source.unit ~= true then
            return false, nil
        end
        if not on_ground and target.unit == true then return false, nil end
        local receipt = {
            position=copy_position(destination),
            occupancy={
                unit=target.unit == true,
                unit_grounded=target.unit_grounded == true,
            },
        }
        if teleport(unit, copy_position(destination)) ~= true then
            return false, nil
        end
        return true, receipt
    end

    ---Restores and verifies one owned unit baseline.
    ---@param unit any
    ---@param baseline table
    function adapter:restore(unit, baseline)
        assert(is_map_loaded(),
            'DwarfSpec could not restore unit position: map is unavailable')
        assert(unit ~= nil,
            'DwarfSpec could not restore unit position: unit is unavailable')
        local departed_position = copy_position(unit.pos)
        if not positions_equal(unit.pos, baseline.position) then
            assert(self:teleport(unit, baseline.position),
                'DwarfSpec could not restore unit position: teleport failed')
        end
        unit.idle_area.x = baseline.idle_area.x
        unit.idle_area.y = baseline.idle_area.y
        unit.idle_area.z = baseline.idle_area.z
        local occupancy = get_occupancy(baseline.position)
        assert(positions_equal(unit.pos, baseline.position),
            'DwarfSpec could not verify restored unit position')
        assert(positions_equal(unit.idle_area, baseline.idle_area),
            'DwarfSpec could not verify restored unit idle area')
        assert(unit.flags1.on_ground == baseline.on_ground,
            'DwarfSpec could not verify restored unit grounded state')
        assert(occupancy ~= nil and
                (occupancy.unit == true) == baseline.occupancy.unit and
                (occupancy.unit_grounded == true) ==
                    baseline.occupancy.unit_grounded,
            'DwarfSpec could not verify restored unit occupancy')
        if not positions_equal(departed_position, baseline.position) then
            local departed = get_occupancy(departed_position)
            local expected = assert(baseline.last_arrival,
                'DwarfSpec could not verify vacated unit occupancy: missing receipt')
            assert(positions_equal(departed_position, expected.position) and
                    departed ~= nil and
                    (departed.unit == true) == expected.occupancy.unit and
                    (departed.unit_grounded == true) ==
                        expected.occupancy.unit_grounded,
                'DwarfSpec could not verify vacated unit occupancy')
        end
    end

    return adapter
end

return M
