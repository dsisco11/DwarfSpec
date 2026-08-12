local Command = require('dwarfspec.driver.builtins.get_game_speed')
local Support = dofile('tests/unit/driver/commands/builtin_test_support.lua')

describe('verified getGameSpeed command', function()
    it('owns and registers its public query', function()
        local runner, ds = Support.register({Command.new(
            Support.game_runtime())})
        assert.equals('getGameSpeed', ds.getGameSpeed())
        assert.same({'getGameSpeed'}, runner:names())
    end)
end)
