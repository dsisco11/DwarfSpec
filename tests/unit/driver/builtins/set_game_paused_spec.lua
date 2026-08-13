local Command = require('dwarfspec.driver.builtins.set_game_paused')
local Outcomes = require('dwarfspec.driver.command.outcomes')
local Support = dofile('tests/unit/driver/commands/builtin_test_support.lua')

describe('verified setGamePaused command', function()
    it('owns exact verification, no-effect handling, and restoration', function()
        local state = false
        local runtime = {pause_state=function() return state end,
            set_pause=function(_, value) state = value return true end}
        local runner, ds = Support.register({Command.new(runtime)})
        assert.equals('setGamePaused', ds.setGamePaused(true))
        local definition = runner:definition('setGamePaused')
        local readiness = definition.preflight({}, {value=true}).value
        local result = definition.execute({}, {value=true}, readiness)
        assert.equals('executed', result.kind)
        assert.is_not_nil(result.effect_receipt)
        assert.equals('ready', definition.verify({}, {value=true},
            result.receipt).kind)
        definition.cleanup.restore({}, result.effect_receipt)
        assert.is_true(definition.cleanup.verify({}, result.effect_receipt))

        readiness = definition.preflight({}, {value=false}).value
        result = definition.execute({}, {value=false}, readiness)
        assert.is_nil(result.effect_receipt)
    end)

    it('retains cleanup ownership after a structured partial effect', function()
        local state = false
        local runtime = {pause_state=function() return state end,
            set_pause=function(_, value)
                state = value
                error('pause dispatch failed')
            end}
        local definition = Command.new(runtime):definition()
        local readiness = definition.preflight({}, {value=true}).value
        local result = definition.execute({}, {value=true}, readiness)
        assert.equals('failed', result.kind)
        assert.is_not_nil(result.effect_receipt)
        assert.matches('pause dispatch failed', result.message, 1, true)
    end)
end)
