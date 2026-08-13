local Command = require('dwarfspec.driver.builtins.set_unit_speed')
local Support = dofile('tests/unit/driver/commands/builtin_test_support.lua')

describe('verified setUnitSpeed command', function()
    it('retains exact target/configuration ownership and restores it', function()
        local state = {active=false,
            recurring={unit_speed_active=false}, configuration=nil}
        local runtime = {
            prepare=function()
                return {fast_actions=true, teleport_jobs=false,
                    unit_ids={4, 9}}
            end,
            activate=function(_, configuration)
                state = {active=true, recurring={unit_speed_active=true},
                    configuration=configuration}
            end,
            state=function() return state end,
            restore=function()
                state = {active=false,
                    recurring={unit_speed_active=false}, configuration=nil}
            end,
        }
        local runner, ds = Support.register({Command.new(runtime)})
        assert.equals('setUnitSpeed', ds.setUnitSpeed({fast_actions=true}))
        local definition = runner:definition('setUnitSpeed')
        local request = {options={fast_actions=true}}
        local readiness = definition.preflight({}, request).value
        local result = definition.execute({}, request, readiness)
        assert.is_not_nil(result.effect_receipt)
        assert.equals('ready', definition.verify({}, request,
            result.receipt).kind)
        definition.cleanup.restore({}, result.effect_receipt)
        assert.is_true(definition.cleanup.verify({}, result.effect_receipt))
    end)

    it('retains cleanup ownership after activation partially fails', function()
        local runtime = {
            prepare=function() return {fast_actions=true,
                teleport_jobs=false, unit_ids={4}} end,
            activate=function() error('scheduler failed') end,
            state=function() return {active=true,
                recurring={unit_speed_active=false}, configuration=nil} end,
            restore=function() end,
        }
        local definition = Command.new(runtime):definition()
        local request = {options={fast_actions=true}}
        local readiness = definition.preflight({}, request).value
        local result = definition.execute({}, request, readiness)
        assert.equals('failed', result.kind)
        assert.is_not_nil(result.effect_receipt)
    end)
end)
