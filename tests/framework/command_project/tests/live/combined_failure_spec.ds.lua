-- Deliberate assertion and cleanup failures used to prove both are retained.

describe('combined example and cleanup failure', function()
    it('reports cleanup without replacing the originating assertion',
            function()
local run = ds.current_run()
        run.cleanup_module.push(run.cleanup_registry,
            'deliberate combined cleanup failure', function()
                error('deliberate cleanup error detail')
            end)

        assert.equals('expected value', 'originating assertion detail')
    end)
end)
