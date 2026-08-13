local UnitSpeedRuntime = require(
    'dwarfspec.driver.runtime.unit_speed_runtime')

describe('unit speed runtime capability', function()
    it('activates the exact prepared snapshot and exposes ownership', function()
        local prepared = {fast_actions=true, teleport_jobs=false,
            unit_ids={4, 9}}
        local activated
        local state = {active=false,
            recurring={unit_speed_active=false}}
        local controller = {
            prepare=function() return prepared end,
            activate_prepared=function(_, value)
                activated = value
                state = {active=true, recurring={unit_speed_active=true},
                    configuration=value}
            end,
            state=function() return state end,
            restore=function()
                state = {active=false,
                    recurring={unit_speed_active=false}}
            end,
        }
        local runtime = UnitSpeedRuntime.new(controller)

        assert.equals(prepared, runtime:prepare({fast_actions=true}))
        runtime:activate(prepared)
        assert.equals(prepared, activated)
        assert.is_true(runtime:state().active)
        runtime:restore()
        assert.is_false(runtime:state().active)
    end)
end)
