---Exercises every supported unit-speed and unit-position declaration.
---@return fun()
local function declaration_fixture()
    return function()
        ds.setUnitSpeed({fast_actions=true})
        ds.setUnitSpeed({teleport_jobs=true, unit_ids={1, 2}})
        ds.setUnitSpeed({fast_actions=true, teleport_jobs=true})

        ---@type dwarfspec.UnitSpeedOptions
        local options = {fast_actions=true, unit_ids={3}}
        ds.setUnitSpeed(options)

        ---@type dwarfspec.UnitPosition
        local position = {x=1, y=2, z=3}
        ds.setUnitPos(3, position)

        local speed_result = ds.setUnitSpeed({fast_actions=true})
        local position_result = ds.setUnitPos(3, position)
        ---@type nil
        local void_speed = speed_result
        ---@type nil
        local void_position = position_result
        assert(void_speed == nil and void_position == nil)
    end
end

return declaration_fixture
