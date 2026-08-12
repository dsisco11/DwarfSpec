local Command = require('dwarfspec.driver.builtins.inspect')
local Support = dofile('tests/unit/driver/commands/builtin_test_support.lua')

describe('verified inspect command', function()
    it('owns and registers its public query', function()
        local runner, ds = Support.register({Command.new(
            Support.mount_runtime())})
        assert.equals('inspect', ds.inspect({}))
        assert.same({'inspect'}, runner:names())
    end)
end)
