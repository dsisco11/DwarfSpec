-- Controlled failing route for native unit-speed cleanup qualification.

local fixture = require('tests.automation.support.unit_speed_fixture')

local original_position

---Returns a copied native coordinate.
---@param position any
---@return table
local function copy_position(position)
    return {x=position.x, y=position.y, z=position.z}
end

describe('unit speed controlled assertion failure', function()
    setup(function()
        fixture.assert_controlled_world()
    end)

    it('01 deliberately fails after owning position and recurring work', function()
        local positioned = fixture.unit(68)
        local accelerated = fixture.unit(72)
        original_position = copy_position(positioned.pos)
        local destination = fixture.destinations(positioned, 1)[1]

        ds.setUnitPos(positioned.id, destination)
        ds.setUnitSpeed({
            fast_actions=true,
            unit_ids={accelerated.id},
        })
        local cleanup = ds.current_run().unit_speed_cleanup_probe()
        assert.is_true(cleanup.unit_speed_active)
        assert.is_true(cleanup.unit_position_active)
        assert.equals(1, cleanup.owned_position_count)
        assert.is_true(false,
            'controlled unit-speed assertion failure after ownership')
    end)

    it('02 observes cleanup from the failed example', function()
        local positioned = fixture.unit(68)
        assert.is_true(fixture.positions_equal(original_position, positioned.pos))
        local cleanup = ds.current_run().unit_speed_cleanup_probe()
        assert.is_false(cleanup.unit_speed_active)
        assert.is_false(cleanup.unit_position_active)
        assert.equals(0, cleanup.owned_position_count)
    end)
end)
