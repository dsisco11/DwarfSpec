local Command = require('dwarfspec.driver.builtins.subject_raw')
local Support = dofile('tests/unit/driver/commands/builtin_test_support.lua')

describe('verified subject.raw command', function()
    it('owns and registers its qualified subject query', function()
        local runner, ds, subject = Support.register({Command.new(
            Support.subject_runtime())})
        assert.equals('subject.raw', subject.raw({}))
        assert.same({'subject.raw'}, runner:names())
        assert.is_nil(ds.raw)
    end)
end)
