local UnitPositionRuntime = require(
    'dwarfspec.driver.runtime.unit_position_runtime')

describe('unit position runtime capability', function()
    it('delegates through the current run-owned adapter', function()
        local calls = {}
        local adapter = {
            prepare=function(_, unit_id, position)
                calls[#calls + 1] = 'prepare'
                return {unit_id=unit_id, destination=position}
            end,
            apply=function(_, readiness)
                calls[#calls + 1] = 'apply'
                return true, readiness
            end,
            observe=function(_, unit_id)
                calls[#calls + 1] = 'observe'
                return {unit_id=unit_id}
            end,
            observe_transition=function(_, unit_id)
                calls[#calls + 1] = 'transition'
                return {unit={unit_id=unit_id}}
            end,
            restore_receipt=function()
                calls[#calls + 1] = 'restore'
            end,
        }
        local runtime = UnitPositionRuntime.new(function() return adapter end)
        local readiness = runtime:prepare(7, {x=1, y=2, z=3})

        assert.is_true(runtime:apply(readiness))
        assert.equals(7, runtime:observe(7).unit_id)
        assert.equals(7,
            runtime:observe_transition(7, readiness).unit.unit_id)
        runtime:restore(readiness)
        assert.same({'prepare', 'apply', 'observe', 'transition', 'restore'},
            calls)
    end)
end)
