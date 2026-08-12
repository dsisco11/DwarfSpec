local Command = require('dwarfspec.driver.builtins.get')
local Support = dofile('tests/unit/driver/commands/builtin_test_support.lua')

describe('verified get command', function()
    it('owns and registers its public query', function()
        local runner, ds = Support.register({Command.new(
            Support.mount_runtime())})
        assert.equals('get', ds.get('path'))
        assert.same({'get'}, runner:names())
    end)
end)
