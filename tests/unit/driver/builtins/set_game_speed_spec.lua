local Command = require('dwarfspec.driver.builtins.set_game_speed')
local Support = dofile('tests/unit/driver/commands/builtin_test_support.lua')

describe('verified setGameSpeed command', function()
    it('owns exact TPS/ratio verification and restoration', function()
        local state = {tps=100, graphical_rate=50, ratio=2}
        local runtime = {speed_state=function()
                return {tps=state.tps, graphical_rate=state.graphical_rate,
                    ratio=state.ratio}
            end,
            set_speed=function(_, value)
                state.tps, state.ratio = value.tps, value.ratio
                return true
            end}
        local runner, ds = Support.register({Command.new(runtime)})
        assert.equals('setGameSpeed', ds.setGameSpeed(80))
        local definition = runner:definition('setGameSpeed')
        local readiness = definition.preflight({}, {tps=80}).value
        local result = definition.execute({}, {tps=80}, readiness)
        assert.equals(80, result.public_result)
        assert.equals('ready', definition.verify({}, {tps=80},
            result.receipt).kind)
        definition.cleanup.restore({}, result.effect_receipt)
        assert.is_true(definition.cleanup.verify({}, result.effect_receipt))
        assert.equals(100, state.tps)
        assert.equals(2, state.ratio)
    end)
end)
