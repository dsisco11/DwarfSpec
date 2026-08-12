local Command = require('dwarfspec.driver.builtins.await_event')
local Support = dofile('tests/unit/driver/commands/builtin_test_support.lua')

describe('verified awaitEvent command owner', function()
    it('owns its definition and validates legacy timeout overrides', function()
        local _, ds = Support.register({Command.new({
            wait_event=function(_, event) return {event=event} end})})
        assert.equals('awaitEvent', ds.awaitEvent('MAP_LOADED'))
        assert.has_error(function()
            ds.awaitEvent('MAP_LOADED', {timeout_ms=1.5}, {timeout_ms=50})
        end, 'wait timeout must be false or a positive finite integer')
    end)
end)
