local module = require('dwarfspec.driver.simulation.unit_target_adapter')

describe('driver unit target adapter', function()
    ---Creates a native-unit adapter fixture.
    ---@return table, table
    local function fixture()
        local state = {
            world=true,
            map=true,
            fortress=true,
            units={},
            enumerated={},
        }
        local adapter = module.new({
            is_world_loaded=function() return state.world end,
            is_map_loaded=function() return state.map end,
            is_fortress_mode=function() return state.fortress end,
            enumerate_units=function() return state.enumerated end,
            resolve_unit=function(id) return state.units[id] end,
            is_active=function(unit) return unit.active end,
            is_alive=function(unit) return unit.alive end,
            is_citizen=function(unit, include_insane)
                assert.is_false(include_insane)
                return unit.citizen
            end,
            is_resident=function(unit, include_insane)
                assert.is_false(include_insane)
                return unit.resident
            end,
        })
        return state, adapter
    end

    ---Creates one eligible unit.
    ---@param id integer
    ---@return table
    local function eligible(id)
        return {id=id, active=true, alive=true, citizen=true, resident=false}
    end

    it('requires a loaded fortress map before activation', function()
        for _, field in ipairs({'world', 'map', 'fortress'}) do
            local state, adapter = fixture()
            state[field] = false
            assert.has_error(function() adapter:assert_ready() end)
            assert.is_false(adapter:is_ready())
        end
    end)

    it('snapshots eligible defaults once in deterministic id order', function()
        local state, adapter = fixture()
        local late = eligible(2)
        state.enumerated = {
            eligible(8),
            {id=1, active=false, alive=true, citizen=true},
            {id=5, active=true, alive=true, citizen=false, resident=true},
        }
        local ids = adapter:capture_default_ids()
        table.insert(state.enumerated, late)

        assert.same({5, 8}, ids)
    end)

    it('reports all invalid and ineligible explicit ids together', function()
        local state, adapter = fixture()
        state.units[1] = eligible(1)
        state.units[3] = {id=3, active=true, alive=false, citizen=true}
        state.units[5] = {id=5, active=true, alive=true,
            citizen=false, resident=false}

        local ok, failure = pcall(function()
            adapter:capture_explicit_ids({1, 2, 3, 4, 5})
        end)

        assert.is_false(ok)
        assert.matches('invalid unit ids: 2, 4', failure, 1, true)
        assert.matches('ineligible unit ids: 3, 5', failure, 1, true)
    end)

    it('bounds explicit-id diagnostics while retaining both categories',
            function()
        local state, adapter = fixture()
        local ids = {}
        for id = 1, 20 do ids[#ids + 1] = id end
        state.units[20] = {id=20, active=false, alive=true, citizen=true}

        local ok, failure = pcall(function()
            adapter:capture_explicit_ids(ids)
        end)

        assert.is_false(ok)
        assert.matches('invalid unit ids:', failure, 1, true)
        assert.matches('(+3 more)', failure, 1, true)
        assert.matches('ineligible unit ids: 20', failure, 1, true)
        assert.is_true(#failure < 256)
    end)

    it('preserves explicit subset order and re-resolves every update', function()
        local state, adapter = fixture()
        state.units[4] = eligible(4)
        state.units[9] = eligible(9)
        local ids = adapter:capture_explicit_ids({9, 4})
        local visited = {}
        adapter:for_each_available(ids, function(unit)
            visited[#visited + 1] = unit
        end)
        local first_nine = visited[1]
        state.units[9] = eligible(9)
        state.units[4].active = false
        visited = {}
        adapter:for_each_available(ids, function(unit)
            visited[#visited + 1] = unit
        end)

        assert.same({9, 4}, ids)
        assert.equals(1, #visited)
        assert.equals(9, visited[1].id)
        assert.not_equals(first_nine, visited[1])
    end)

    it('skips the whole update when loaded fortress state disappears', function()
        local state, adapter = fixture()
        state.units[1] = eligible(1)
        state.map = false
        local calls = 0

        assert.is_false(adapter:for_each_available({1}, function()
            calls = calls + 1
        end))
        assert.equals(0, calls)
    end)
end)
