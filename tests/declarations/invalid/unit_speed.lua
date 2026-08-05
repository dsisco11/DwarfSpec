---Supplies intentionally invalid unit-speed and position declarations.
---@return fun()
local function invalid_declaration_fixture()
    return function()
        ds.setUnitSpeed({fast_actions='yes'})
        ds.setUnitSpeed({fast_movement='yes'})
        ds.setUnitSpeed({teleport_jobs=1})
        ds.setUnitSpeed({fast_movement=true, unit_ids={1}})
        ds.setUnitSpeed({unit_ids={'one'}})
        ---@type dwarfspec.UnitSpeedOptions
        local options_with_unknown_field = {fast_actions=true}
        options_with_unknown_field.surprise = true
        ds.setUnitPos('one', {x=1, y=2, z=3})
        ds.setUnitPos(1, {x='one', y=2, z=3})
        ds.setUnitPos(1, {x=1, y=2})
        ---@type dwarfspec.UnitPosition
        local position_with_unknown_field = {x=1, y=2, z=3}
        position_with_unknown_field.surprise = true
    end
end

return invalid_declaration_fixture
