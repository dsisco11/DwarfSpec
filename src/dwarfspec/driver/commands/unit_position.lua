-- Explicit unit-position command binding for one DwarfSpec run.

local M = {}

---Binds explicit unit positioning to the public run-scoped namespace.
---@param ds table
---@param dependencies table
function M.bind(ds, dependencies)
    assert(type(ds) == 'table', 'unit position command requires ds namespace')
    local controller = assert(dependencies.position_controller,
        'unit position command requires position controller')

    ---Teleports one valid unit to a valid loaded-map position.
    ---@param unit_id integer
    ---@param position table
    function ds.setUnitPos(unit_id, position)
        assert(controller:move(unit_id, position),
            'DwarfSpec could not safely set the unit position')
    end
end

return M
