-- Live contracts for frame scheduling and test-owned cleanup.

describe('automation scheduler and cleanup', function()
    ---Returns the cleanup registry owned by the active automation run.
    ---@return table, table
    local function active_cleanup()
        local run = assert(dfhack.dwarfspec.active_run,
            'automation run is not active')
        return run.cleanup_module, run.cleanup_registry
    end

    it('resumes after real raw-frame callbacks', function()
        local run = assert(dfhack.dwarfspec.active_run)
        local started_ms = dfhack.getTickCount()

        local elapsed_frames = ds.wait_frames(3)

        assert.equals(3, elapsed_frames)
        assert.is_true(dfhack.getTickCount() >= started_ms)
        assert.is_nil(run.outstanding_wait)
    end)

    it('polls a read-only condition between frames', function()
        local observations = 0

        local value = ds.await('third observation', function()
            observations = observations + 1
            return observations == 3 and 'ready' or false
        end, {frame_budget=5, timeout_ms=2000})

        assert.equals('ready', value)
        assert.equals(3, observations)
    end)

    it('reports actionable timeout and interaction diagnostics', function()
        local timeout_ok, timeout_error = pcall(ds.await,
            'deliberately absent value', function() return false end,
            {frame_budget=2, timeout_ms=2000})
        local query_ok, query_error = pcall(ds.await,
            'deliberately broken query', function()
                error('deliberate query failure')
            end, {frame_budget=2, timeout_ms=2000})

        assert.is_false(timeout_ok)
        assert.matches('automation wait timed out', timeout_error, 1, true)
        assert.matches('operation="deliberately absent value"',
            timeout_error, 1, true)
        assert.matches('elapsed_frames=2', timeout_error, 1, true)
        assert.matches('last_observed=false', timeout_error, 1, true)
        assert.matches('focus="dwarfmode/Default"', timeout_error, 1, true)
        assert.matches('screen=', timeout_error, 1, true)
        assert.not_matches('focus=<table>', timeout_error, 1, true)
        assert.is_false(query_ok)
        assert.matches('automation interaction error', query_error, 1, true)
        assert.matches('deliberate query failure', query_error, 1, true)
    end)

    it('cleans once in LIFO order and permits repeated reset', function()
        local cleanup, registry = active_cleanup()
        local order = {}
        cleanup.push(registry, 'first live resource', function()
            table.insert(order, 'first')
        end)
        cleanup.push(registry, 'second live resource', function()
            table.insert(order, 'second')
        end)

        ds.reset()
        ds.reset()

        assert.same({'second', 'first'}, order)
        assert.equals(0, cleanup.pending_count(registry))
    end)

    it('rejects waits from a non-owner coroutine', function()
        local wait_ok
        local wait_error
        local rogue = coroutine.create(function()
            wait_ok, wait_error = pcall(ds.wait_frames, 1)
        end)

        assert.is_true(coroutine.resume(rogue))
        assert.equals('dead', coroutine.status(rogue))
        assert.is_false(wait_ok)
        assert.matches('active automation suite coroutine', wait_error,
            1, true)
    end)
end)
