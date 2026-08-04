local module = require('dwarfspec.driver.commands.unit_position')

describe('driver unit position command', function()
    it('returns nil after delegating to the shared controller', function()
        local ds = {}
        local calls = {}
        module.bind(ds, {position_controller={move=function(_, id, position)
            calls[#calls + 1] = {id=id, position=position}
            return true
        end}})
        local result = ds.setUnitPos(8, {x=1, y=2, z=3})
        assert.is_nil(result)
        assert.same({{id=8, position={x=1, y=2, z=3}}}, calls)
    end)

    it('reports rejected positioning without adding another mutation path', function()
        local ds = {}
        module.bind(ds, {position_controller={move=function() return false end}})
        assert.has_error(function()
            ds.setUnitPos(8, {x=1, y=2, z=3})
        end, 'DwarfSpec could not safely set the unit position')
    end)

    it('supports a valid noncitizen without changing unrelated game state',
            function()
        local ds = {}
        local unit = {id=19, citizen=false, job={id=4}, path={1, 2, 3}}
        local state = {paused=true, tps=100}
        module.bind(ds, {position_controller={move=function(_, id)
            assert.equals(unit.id, id)
            unit.position = {x=4, y=5, z=6}
            return true
        end}})
        ds.setUnitPos(19, {x=4, y=5, z=6})
        assert.is_false(unit.citizen)
        assert.same({id=4}, unit.job)
        assert.same({1, 2, 3}, unit.path)
        assert.is_true(state.paused)
        assert.equals(100, state.tps)
    end)
end)
