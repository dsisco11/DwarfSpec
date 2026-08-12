local CommandKind = require('dwarfspec.protocol.enums.command_kinds')
local GameQueries = require(
    'dwarfspec.driver.commands.game_query_definition')
local TestRunner = dofile(
    'tests/unit/driver/commands/definition_test_support.lua')

describe('verified scalar game query definitions', function()
    it('owns every scalar query and preserves public arguments', function()
        local runner, ds = TestRunner.new(), {}
        local queries = {isGamePaused=function() return false end,
            getGameSpeed=function() return 100 end,
            getTick=function() return 7 end, getTime=function() return 9 end,
            getSaveDirectoryName=function() return 'region1' end,
            hasFocus=function(path) return path == 'dwarfmode' end}
        GameQueries.bind(ds, runner, queries)
        local options = {timeout_ms=10}
        assert.equals('isGamePaused', ds.isGamePaused(options))
        assert.equals('hasFocus', ds.hasFocus('dwarfmode', options))
        assert.equals('dwarfmode', runner:invocations()[2].arguments.path)
        assert.equals(options, runner:invocations()[2].options)
        for _, name in ipairs(runner:names()) do
            assert.equals(CommandKind.QUERY, runner:definition(name).kind)
        end
    end)
end)
