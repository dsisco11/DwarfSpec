local Command = require('dwarfspec.driver.builtins.get_tick')
local Support = dofile('tests/unit/driver/commands/builtin_test_support.lua')

describe('verified getTick command', function()
    it('owns and registers its public query', function()
        local runner, ds = Support.register({Command.new(
            Support.game_runtime())})
        assert.equals('getTick', ds.getTick())
        assert.same({'getTick'}, runner:names())
    end)
end)
