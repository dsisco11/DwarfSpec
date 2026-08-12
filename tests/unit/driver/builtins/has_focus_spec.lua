local Command = require('dwarfspec.driver.builtins.has_focus')
local Support = dofile('tests/unit/driver/commands/builtin_test_support.lua')

describe('verified hasFocus command', function()
    it('owns and registers its public query', function()
        local runner, ds = Support.register({Command.new(
            Support.game_runtime())})
        assert.equals('hasFocus', ds.hasFocus('dwarfmode'))
        assert.same({'hasFocus'}, runner:names())
    end)
end)
