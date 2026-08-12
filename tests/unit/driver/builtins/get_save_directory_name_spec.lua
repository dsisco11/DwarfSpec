local Command = require(
    'dwarfspec.driver.builtins.get_save_directory_name')
local Support = dofile('tests/unit/driver/commands/builtin_test_support.lua')

describe('verified getSaveDirectoryName command', function()
    it('owns and registers its public query', function()
        local runner, ds = Support.register({Command.new(
            Support.game_runtime())})
        assert.equals('getSaveDirectoryName', ds.getSaveDirectoryName())
        assert.same({'getSaveDirectoryName'}, runner:names())
    end)
end)
