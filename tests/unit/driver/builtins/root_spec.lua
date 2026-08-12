local Command = require('dwarfspec.driver.builtins.root')
local Support = dofile('tests/unit/driver/commands/builtin_test_support.lua')

describe('verified root command', function()
    it('owns and registers its public query', function()
        local runner, ds = Support.register({Command.new(
            Support.mount_runtime())})
        assert.equals('root', ds.root())
        assert.same({'root'}, runner:names())
    end)
end)
