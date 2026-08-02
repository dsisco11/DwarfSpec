local command = require('dwarfspec.driver.commands.wait')

describe('wait command binding', function()
    it('applies defaults and delegates event waits', function()
        local ds, calls = {}, {}
        command.bind(ds, {scheduler={}, wait_settings={timeout_ms=12, frame_budget=3},
            scheduler_module={wait_frames=function(_, count, options)
                calls.options = options; return count
            end}, await_event=function(event) return event end})
        assert.equals(2, ds.wait_frames(2))
        assert.same({timeout_ms=12}, calls.options)
        assert.equals('MAP_LOADED', ds.awaitEvent('MAP_LOADED'))
    end)
end)
