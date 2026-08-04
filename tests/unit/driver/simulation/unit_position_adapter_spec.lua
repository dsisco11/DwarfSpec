local module = require('dwarfspec.driver.simulation.unit_position_adapter')

describe('driver unit position adapter', function()
    ---Creates native position and occupancy doubles.
    ---@return table, table
    local function fixture()
        local state = {map_loaded=true, valid=true, projectile=false,
            rider=false, ridden=false, teleport_result=true, teleports=0,
            occupancies={}, invalid_positions={}, corrupt_return=nil}
        local unit = {id=3, pos={x=1, y=2, z=3},
            idle_area={x=1, y=2, z=3}, flags1={on_ground=false}}
        state.unit = unit
        state.occupancies['1,2,3'] = {unit=true, unit_grounded=false}
        state.occupancies['5,6,3'] = {unit=false, unit_grounded=false}
        local function key(position)
            return ('%d,%d,%d'):format(position.x, position.y, position.z)
        end
        local adapter = module.new({
            is_map_loaded=function() return state.map_loaded end,
            is_valid_position=function(position)
                return state.valid and not state.invalid_positions[key(position)]
            end,
            resolve_unit=function(id) return id == 3 and state.unit or nil end,
            get_occupancy=function(position) return state.occupancies[key(position)] end,
            is_projectile=function() return state.projectile end,
            has_rider=function() return state.ridden end,
            is_rider=function() return state.rider end,
            teleport=function(target, destination)
                state.teleports = state.teleports + 1
                if not state.teleport_result then return false end
                local source = state.occupancies[key(target.pos)]
                local arrival = state.occupancies[key(destination)]
                if target.flags1.on_ground then
                    source.unit_grounded = false
                    arrival.unit_grounded = true
                else
                    source.unit = false
                    arrival.unit = true
                end
                target.pos = {x=destination.x, y=destination.y, z=destination.z}
                target.idle_area = {x=destination.x, y=destination.y,
                    z=destination.z}
                if state.corrupt_return and key(destination) == '1,2,3' then
                    local corrupt = state.corrupt_return
                    state.occupancies[corrupt.tile][corrupt.field] = corrupt.value
                end
                return true
            end,
        })
        return state, adapter
    end

    it('copies coordinates and captures position, idle area, and grounded state',
            function()
        local state, adapter = fixture()
        local input = {x=5, y=6, z=3}
        local copied = adapter:normalize_position(input)
        input.x = 99
        assert.same({x=5, y=6, z=3}, copied)
        assert.same({position={x=1, y=2, z=3},
            idle_area={x=1, y=2, z=3}, on_ground=false,
            occupancy={unit=true, unit_grounded=false}},
            adapter:capture_baseline(state.unit))
    end)

    it('rejects projectile, rider, ridden, and inconsistent occupancy states',
            function()
        for _, field in ipairs({'projectile', 'rider', 'ridden'}) do
            local state, adapter = fixture()
            state[field] = true
            assert.is_nil(adapter:capture_baseline(state.unit))
            assert.is_false(adapter:teleport(state.unit, {x=5, y=6, z=3}))
        end
        local state, adapter = fixture()
        state.occupancies['1,2,3'].unit = false
        assert.is_nil(adapter:capture_baseline(state.unit))
        assert.is_false(adapter:teleport(state.unit, {x=5, y=6, z=3}))
    end)

    it('rejects occupied destinations for standing arrivals', function()
        local state, adapter = fixture()
        state.occupancies['5,6,3'].unit = true
        assert.is_false(adapter:teleport(state.unit, {x=5, y=6, z=3}))
        assert.equals(0, state.teleports)
    end)

    it('independently rejects unavailable maps and invalid coordinates', function()
        local state, adapter = fixture()
        state.map_loaded = false
        assert.is_nil(adapter:normalize_position({x=5, y=6, z=3}))
        assert.is_nil(adapter:capture_baseline(state.unit))
        assert.is_false(adapter:teleport(state.unit, {x=5, y=6, z=3}))
        state.map_loaded = true
        state.invalid_positions['1,2,3'] = true
        assert.is_nil(adapter:capture_baseline(state.unit))
        assert.is_false(adapter:teleport(state.unit, {x=5, y=6, z=3}))
        state.invalid_positions['1,2,3'] = nil
        state.invalid_positions['5,6,3'] = true
        assert.is_false(adapter:teleport(state.unit, {x=5, y=6, z=3}))
    end)

    it('independently rejects identical and missing-occupancy destinations',
            function()
        local state, adapter = fixture()
        assert.is_false(adapter:teleport(state.unit, {x=1, y=2, z=3}))
        state.occupancies['5,6,3'] = nil
        assert.is_false(adapter:teleport(state.unit, {x=5, y=6, z=3}))
        state.occupancies['5,6,3'] = {unit=false, unit_grounded=false}
        state.occupancies['1,2,3'] = nil
        assert.is_false(adapter:teleport(state.unit, {x=5, y=6, z=3}))
    end)

    it('rejects both standing and grounded source mismatches', function()
        local state, adapter = fixture()
        state.occupancies['1,2,3'].unit = false
        assert.is_nil(adapter:capture_baseline(state.unit))
        state, adapter = fixture()
        state.unit.flags1.on_ground = true
        state.occupancies['1,2,3'] = {unit=true, unit_grounded=false}
        assert.is_nil(adapter:capture_baseline(state.unit))
    end)

    it('allows occupied destinations for already-grounded arrivals', function()
        local state, adapter = fixture()
        state.unit.flags1.on_ground = true
        state.occupancies['1,2,3'] = {unit=false, unit_grounded=true}
        state.occupancies['5,6,3'].unit = true
        local baseline = adapter:capture_baseline(state.unit)
        local moved, receipt = adapter:teleport(
            state.unit, {x=5, y=6, z=3})
        assert.is_true(moved)
        assert.equals(1, state.teleports)
        baseline.last_arrival = receipt
        adapter:restore(state.unit, baseline)
        assert.is_true(state.occupancies['5,6,3'].unit)
        assert.is_false(state.occupancies['5,6,3'].unit_grounded)
    end)

    it('leaves position unchanged when native teleport fails', function()
        local state, adapter = fixture()
        state.teleport_result = false
        assert.is_false(adapter:teleport(state.unit, {x=5, y=6, z=3}))
        assert.same({x=1, y=2, z=3}, state.unit.pos)
    end)

    it('restores and verifies position, idle area, grounded state, and occupancy',
            function()
        local state, adapter = fixture()
        local baseline = adapter:capture_baseline(state.unit)
        local moved, receipt = adapter:teleport(state.unit, {x=5, y=6, z=3})
        assert.is_true(moved)
        baseline.last_arrival = receipt
        adapter:restore(state.unit, baseline)
        assert.same({x=1, y=2, z=3}, state.unit.pos)
        assert.same({x=1, y=2, z=3}, state.unit.idle_area)
        assert.is_true(state.occupancies['1,2,3'].unit)
        assert.is_false(state.occupancies['5,6,3'].unit)
    end)

    it('fails restoration when map, unit, teleport, or verification is invalid',
            function()
        local state, adapter = fixture()
        local baseline = adapter:capture_baseline(state.unit)
        state.map_loaded = false
        assert.has_error(function() adapter:restore(state.unit, baseline) end)
        state.map_loaded = true
        assert.has_error(function() adapter:restore(nil, baseline) end)
        local _, receipt = adapter:teleport(state.unit, {x=5, y=6, z=3})
        baseline.last_arrival = receipt
        state.teleport_result = false
        assert.has_error(function() adapter:restore(state.unit, baseline) end)
    end)

    it('rejects either restored or vacated occupancy-bit corruption', function()
        for _, corruption in ipairs({
            {tile='1,2,3', field='unit_grounded', value=true},
            {tile='5,6,3', field='unit_grounded', value=true},
        }) do
            local state, adapter = fixture()
            local baseline = adapter:capture_baseline(state.unit)
            local _, receipt = adapter:teleport(state.unit, {x=5, y=6, z=3})
            baseline.last_arrival = receipt
            state.corrupt_return = corruption
            assert.has_error(function() adapter:restore(state.unit, baseline) end)
        end
    end)
end)
