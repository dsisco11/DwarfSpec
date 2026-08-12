local Command = require('dwarfspec.driver.builtins.capture_view_tree')
local Support = dofile('tests/unit/driver/commands/builtin_test_support.lua')

describe('verified capture_view_tree command', function()
    it('owns and registers its public query', function()
        local runner, ds = Support.register({Command.new(
            Support.mount_runtime())})
        assert.equals('capture_view_tree', ds.capture_view_tree('tree'))
        assert.same({'capture_view_tree'}, runner:names())
    end)
end)
