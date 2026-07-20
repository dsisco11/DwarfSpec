-- Live resilience contracts for reusable automation-host infrastructure.

---Derives the repository root from this live spec's absolute source path.
---@return string
local function repository_root()
    local source = debug.getinfo(1, 'S').source:gsub('^@', '')
    local root = source:match('^(.*)[/\\]Tests[/\\]Automation[/\\]specs[/\\]' ..
        'framework_hardening_live_spec%.lua$')
    return assert(root, 'could not derive repository root from ' .. source)
end

---Returns the active run's cleanup module and registry.
---@return table, table
local function active_cleanup()
    local run = assert(dfhack.dwarfui.automation.active_run,
        'automation run is not active')
    return run.cleanup_module, run.cleanup_registry
end

---Builds the smallest valid competing host-run option set.
---@param run_id string
---@return table
local function competing_options(run_id)
    return {
        run_id=run_id,
        defer_frames=1,
        lease_timeout_ms=1000,
        lease_check_frames=1,
    }
end

describe('automation framework live resilience', function()
    before_each(function()
        dy.reset()
    end)

    after_each(function()
        dy.reset()
    end)

    it('rejects a competing host run without changing the active owner',
            function()
        local root = repository_root()
        local host = assert(loadfile(root ..
            '/Tests/Automation/support/busted_host.lua'))()
        local active = assert(dfhack.dwarfui.automation.active_run)

        local ok, message = pcall(host.start, root,
            competing_options('live-host-conflict'))

        assert.is_false(ok)
        assert.matches('automation run ' .. active.run_id ..
            ' is already running', message, 1, true)
        assert.equals(active, dfhack.dwarfui.automation.active_run)
    end)

    it('rejects stale real-frame callbacks from a no-longer-current generation',
            function()
        local root = repository_root()
        local scheduler_module = assert(loadfile(root ..
            '/Tests/Automation/support/scheduler.lua'))()
        local run = {outstanding_wait=nil, suspended=false}
        local complete_calls = 0
        local stale_callback
        local current = true
        local scheduler = scheduler_module.new(run, {
            is_current=function() return current end,
            schedule_timeout=function(delay, callback)
                assert.equals(1, delay)
                stale_callback = callback
                return 'stale-callback'
            end,
            cancel_timeout=function(timeout_id)
                assert.equals('stale-callback', timeout_id)
            end,
            now_ms=dfhack.getTickCount,
            diagnostics=function()
                return {focus='live', screen='live'}
            end,
            on_complete=function()
                complete_calls = complete_calls + 1
            end,
        })
        local owner = coroutine.create(function()
            scheduler_module.wait_frames(scheduler, 1)
        end)
        scheduler_module.bind(scheduler, owner)

        local resumed, yielded = coroutine.resume(owner)
        assert.is_true(resumed)
        assert.is_true(scheduler_module.owns_yield(scheduler, yielded))

        current = false
        dfhack.timeout(1, 'frames', stale_callback)
        dy.wait_frames(2)

        assert.equals(1, run.scheduler_state.stale_callback_count)
        assert.equals(0, complete_calls)
        scheduler_module.cancel(scheduler, 'test stale-generation cleanup')
    end)

    it('captures injected fixture failures and restores test-owned state',
            function()
        local ok, message = pcall(dy.show_fixture, 'failing_screen')
        local run = assert(dfhack.dwarfui.automation.active_run)

        assert.is_false(ok)
        assert.matches('operation="show fixture failing_screen"', message,
            1, true)
        assert.matches('deliberate automation fixture construction failure',
            message, 1, true)
        assert.equals('show fixture failing_screen',
            run.last_interaction_diagnostics.operation)
        assert.equals(0, run.cleanup_module.pending_count(
            run.cleanup_registry))
    end)

    it('retains cleanup diagnostics after an injected cleanup failure',
            function()
        local cleanup, registry = active_cleanup()
        cleanup.push(registry, 'deliberate live cleanup failure', function()
            error('deliberate live cleanup failure')
        end)

        local ok, message = pcall(dy.reset)

        assert.is_false(ok)
        assert.matches('automation cleanup failed', message, 1, true)
        assert.equals(1, #registry.failures)
        assert.equals('deliberate live cleanup failure',
            registry.failures[1].name)
        assert.equals(0, cleanup.pending_count(registry))
    end)
end)
