local Command = require('dwarfspec.driver.builtins.get_time')
local Support = dofile('tests/unit/driver/commands/builtin_test_support.lua')

describe('verified getTime command', function()
    it('owns and registers its public query', function()
        local runner, ds = Support.register({Command.new(
            Support.game_runtime())})
        assert.equals('getTime', ds.getTime())
        assert.same({'getTime'}, runner:names())
    end)
end)
