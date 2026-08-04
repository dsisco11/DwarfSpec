local module = require('dwarfspec.driver.simulation.unit_job_travel')

describe('driver unit job travel', function()
    ---Creates guarded travel doubles.
    ---@return table, table
    local function fixture()
        local unit = {
            id=5, pos={x=1, y=2, z=3},
            path={dest={x=8, y=9, z=3},
                path={x={1, 8}, y={2, 9}, z={3, 3}}},
            relationship_ids={dragger=-1, draggee=-1}, following=nil,
            counters={unconscious=0}, job={current_job={id=11}},
        }
        local state = {unit=unit, invalid={}, connected=true, visible=true,
            move_result=true, moves={}, clears={}}
        local function key(position)
            return ('%d,%d,%d'):format(position.x, position.y, position.z)
        end
        local travel = module.new({
            resolve_unit=function(id) return id == 5 and state.unit or nil end,
            is_valid_position=function(position)
                return not state.invalid[key(position)]
            end,
            can_walk_between=function() return state.connected end,
            is_tile_visible=function() return state.visible end,
            position_controller={move=function(_, id, destination)
                state.moves[#state.moves + 1] = {id=id, destination=destination}
                return state.move_result
            end},
            dragger_relationship='dragger',
            draggee_relationship='draggee',
            resize_vector=function(vector, size)
                assert.equals(0, size)
                state.clears[#state.clears + 1] = vector
                for index = #vector, 1, -1 do vector[index] = nil end
            end,
        })
        return state, travel
    end

    it('moves once and clears the path only after success', function()
        local state, travel = fixture()
        assert.is_true(travel:attempt(5))
        assert.equals(1, #state.moves)
        assert.not_equals(state.unit.path.dest, state.moves[1].destination)
        assert.same({x=8, y=9, z=3}, state.moves[1].destination)
        assert.equals(3, #state.clears)
        assert.same({}, state.unit.path.path.x)
        assert.same({}, state.unit.path.path.y)
        assert.same({}, state.unit.path.path.z)
        state.unit.path.path = {x={1}, y={2}, z={3}}
        state.move_result = false
        assert.is_false(travel:attempt(5))
        assert.equals(2, #state.moves)
        assert.equals(3, #state.clears)
        assert.same({1}, state.unit.path.path.x)
        assert.same({2}, state.unit.path.path.y)
        assert.same({3}, state.unit.path.path.z)
    end)

    it('independently skips every fastdwarf job guard', function()
        local mutations = {
            function(unit) unit.relationship_ids.dragger = 9 end,
            function(unit) unit.relationship_ids.draggee = 9 end,
            function(unit) unit.following = {id=9} end,
            function(unit) unit.counters.unconscious = 1 end,
            function(unit) unit.job.current_job = nil end,
            function(unit) unit.path.dest = unit.pos end,
        }
        for _, mutate in ipairs(mutations) do
            local state, travel = fixture()
            mutate(state.unit)
            assert.is_false(travel:attempt(5))
            assert.equals(0, #state.moves)
        end
    end)

    it('skips invalid, disconnected, and hidden destinations', function()
        for _, field in ipairs({'source', 'destination', 'connected', 'visible'}) do
            local state, travel = fixture()
            if field == 'source' then
                state.invalid['1,2,3'] = true
            elseif field == 'destination' then
                state.invalid['8,9,3'] = true
            else
                state[field] = false
            end
            assert.is_false(travel:attempt(5))
            assert.equals(0, #state.moves)
            assert.equals(0, #state.clears)
            assert.same({1, 8}, state.unit.path.path.x)
            assert.same({2, 9}, state.unit.path.path.y)
            assert.same({3, 3}, state.unit.path.path.z)
        end
    end)

    it('re-resolves the unit for every attempt', function()
        local state, travel = fixture()
        state.unit = nil
        assert.is_false(travel:attempt(5))
        assert.equals(0, #state.moves)
    end)
end)
