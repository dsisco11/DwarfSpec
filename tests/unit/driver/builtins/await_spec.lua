local Command = require('dwarfspec.driver.builtins.await')
local Support = dofile('tests/unit/driver/commands/builtin_test_support.lua')

describe('verified await command', function()
    it('owns its definition and preserves the query function', function()
        local runner, ds = Support.register({Command.new({
            wait_until=function(_, _, query) return query() end})})
        local query = function() return true end
        assert.equals('await', ds.await('ready', query))
        assert.equals(query, runner:invocations()[1].arguments.query)
    end)
end)
