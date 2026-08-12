local CommandKind = require('dwarfspec.protocol.enums.command_kinds')
local SubjectQueries = require(
    'dwarfspec.driver.commands.subject_query_definition')
local TestRunner = dofile(
    'tests/unit/driver/commands/definition_test_support.lua')

describe('verified subject-only query definitions', function()
    it('owns focus-list and raw subject query invocation', function()
        local subject = {}
        local runner = TestRunner.new()
        local queries = SubjectQueries.bind(runner, {
            getFocusList=function(value)
                assert.equals(subject, value)
                return {'focus'}
            end,
            raw=function(value)
                assert.equals(subject, value)
                return value
            end,
        })
        local options = {timeout_ms=10}
        assert.equals('subject.getFocusList',
            queries.getFocusList(subject, options))
        assert.equals('subject.raw', queries.raw(subject, options))
        assert.same({'subject.getFocusList', 'subject.raw'}, runner:names())
        for _, name in ipairs(runner:names()) do
            assert.equals(CommandKind.QUERY, runner:definition(name).kind)
        end
    end)
end)
