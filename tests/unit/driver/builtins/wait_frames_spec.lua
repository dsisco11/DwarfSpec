local Command = require('dwarfspec.driver.builtins.wait_frames')
local Support = dofile('tests/unit/driver/commands/builtin_test_support.lua')

describe('verified wait_frames command', function()
    it('owns its definition and public argument adapter', function()
        local runner, ds = Support.register({Command.new({
            wait_frames=function(_, count) return count end})})
        assert.equals('wait_frames', ds.wait_frames(2, nil, {timeout_ms=9}))
        assert.same({'wait_frames'}, runner:names())
        assert.equals(2, runner:invocations()[1].arguments.count)
        assert.equals(9, runner:invocations()[1].options.timeout_ms)
    end)
end)
