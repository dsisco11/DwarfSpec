local Command = require(
    'dwarfspec.driver.builtins.subject_get_focus_list')
local Support = dofile('tests/unit/driver/commands/builtin_test_support.lua')

describe('verified subject.getFocusList command', function()
    it('owns and registers its qualified subject query', function()
        local runner, ds, subject = Support.register({Command.new(
            Support.subject_runtime())})
        assert.equals('subject.getFocusList', subject.getFocusList({}))
        assert.same({'subject.getFocusList'}, runner:names())
        assert.is_nil(ds.getFocusList)
    end)
end)
