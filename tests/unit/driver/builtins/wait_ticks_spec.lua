local Command = require('dwarfspec.driver.builtins.wait_ticks')
local Support = dofile('tests/unit/driver/commands/builtin_test_support.lua')

describe('verified wait_ticks command', function()
    it('owns its definition and public argument adapter', function()
        local runner, ds = Support.register({Command.new({
            wait_ticks=function(_, count) return count end})})
        assert.equals('wait_ticks', ds.wait_ticks(3))
        assert.equals(3, runner:invocations()[1].arguments.count)
    end)
end)
