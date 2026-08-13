local Command = require('dwarfspec.driver.builtins.set_unit_pos')
local Support = dofile('tests/unit/driver/commands/builtin_test_support.lua')

describe('verified setUnitPos command', function()
    it('preflights source/destination occupancy and verifies restoration',
            function()
        local baseline = {position={x=1, y=2, z=3},
            idle_area={x=1, y=2, z=3}, on_ground=false,
            occupancy={unit=true, unit_grounded=false}}
        local observed = baseline
        local runtime = {
            prepare=function(_, unit_id, destination)
                return {unit_id=unit_id, destination=destination,
                    baseline=baseline,
                    destination_occupancy={unit=false,
                        unit_grounded=false}}
            end,
            apply=function(_, readiness)
                observed = {position=readiness.destination,
                    idle_area=readiness.destination, on_ground=false,
                    occupancy={unit=true, unit_grounded=false}}
                return true, {unit_id=readiness.unit_id,
                    baseline=baseline, destination=readiness.destination,
                    arrival={position=readiness.destination,
                        occupancy={unit=false, unit_grounded=false}}}
            end,
            observe=function() return observed end,
            observe_transition=function()
                return {unit=observed,
                    source={unit=false, unit_grounded=false},
                    destination={unit=true, unit_grounded=false}}
            end,
            restore=function() observed = baseline end,
        }
        local runner, ds = Support.register({Command.new(runtime)})
        assert.equals('setUnitPos', ds.setUnitPos(4, {x=5, y=6, z=7}))
        local definition = runner:definition('setUnitPos')
        local request = {unit_id=4, position={x=5, y=6, z=7}}
        local readiness = definition.preflight({}, request).value
        local result = definition.execute({}, request, readiness)
        assert.is_not_nil(result.effect_receipt)
        assert.equals('ready', definition.verify({}, request,
            result.receipt).kind)
        runtime.observe_transition=function()
            return {unit=observed,
                source={unit=true, unit_grounded=false},
                destination={unit=true, unit_grounded=false}}
        end
        assert.equals('pending', definition.verify({}, request,
            result.receipt).kind)
        definition.cleanup.restore({}, result.effect_receipt)
        assert.is_true(definition.cleanup.verify({}, result.effect_receipt))
    end)

    it('retains observed partial movement when the adapter reports failure',
            function()
        local baseline = {position={x=1, y=2, z=3},
            idle_area={x=1, y=2, z=3}, on_ground=false,
            occupancy={unit=true, unit_grounded=false}}
        local destination = {x=5, y=6, z=7}
        local runtime = {
            prepare=function()
                return {unit_id=4, destination=destination,
                    baseline=baseline,
                    destination_occupancy={unit=false,
                        unit_grounded=false}}
            end,
            apply=function() return false end,
            observe=function()
                return {position=destination, idle_area=destination,
                    on_ground=false,
                    occupancy={unit=true, unit_grounded=false}}
            end,
            observe_transition=function() end,
            restore=function() end,
        }
        local definition = Command.new(runtime):definition()
        local request = {unit_id=4, position=destination}
        local readiness = definition.preflight({}, request).value

        local result = definition.execute({}, request, readiness)

        assert.equals('failed', result.kind)
        assert.is_not_nil(result.effect_receipt)
        assert.same(destination, result.effect_receipt.arrival.position)
    end)
end)
