local Command = require('dwarfspec.driver.builtins.set_turbo_speed')
local Support = dofile('tests/unit/driver/commands/builtin_test_support.lua')

describe('verified setTurboSpeed command', function()
    it('owns exact native turbo state and its baseline', function()
        local state = false
        local runtime = {turbo_state=function() return state end,
            set_turbo=function(_, value) state = value return true end}
        local runner, ds = Support.register({Command.new(runtime)})
        assert.equals('setTurboSpeed', ds.setTurboSpeed(true))
        local definition = runner:definition('setTurboSpeed')
        local readiness = definition.preflight({}, {value=true}).value
        local result = definition.execute({}, {value=true}, readiness)
        assert.equals(true, result.public_result)
        assert.is_not_nil(result.effect_receipt)
        definition.cleanup.restore({}, result.effect_receipt)
        assert.is_true(definition.cleanup.verify({}, result.effect_receipt))
    end)
end)
