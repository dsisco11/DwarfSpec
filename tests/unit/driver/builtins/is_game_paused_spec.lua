local Command = require('dwarfspec.driver.builtins.is_game_paused')
local Support = dofile('tests/unit/driver/commands/builtin_test_support.lua')

describe('verified isGamePaused command', function()
    it('owns and registers its public query', function()
        local runner, ds = Support.register({Command.new(
            Support.game_runtime())})
        assert.equals('isGamePaused', ds.isGamePaused())
        assert.same({'isGamePaused'}, runner:names())
    end)
end)
