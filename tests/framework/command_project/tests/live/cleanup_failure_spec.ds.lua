-- Deliberate cleanup failure used to prove cleanup error propagation.

describe('command runner cleanup failure path', function()
    it('reports a failing automatic cleanup hook', function()
        local run = assert(dfhack.dwarfspec.active_run)
        run.cleanup_module.push(run.cleanup_registry,
            'deliberate command cleanup failure', function()
                error('deliberate command cleanup failure')
            end)
    end)
end)
