local module = require('dwarfspec.host.execution.run_lifecycle')

---Creates lifecycle dependencies that record externally visible operations.
---@param calls string[]
---@param overrides table|nil
---@return table
local function dependencies(calls, overrides)
    local values = {
        states={starting='starting', running='running', passed='passed',
            failed='failed', aborted='aborted'},
        events={cleanup_failed='cleanup_failed',
            cleanup_finished='cleanup_finished', run_aborted='run_aborted'},
        publish_event=function(_, kind)
            table.insert(calls, 'publish:' .. kind)
        end,
        begin_cleanup=function() table.insert(calls, 'begin_cleanup') end,
        complete_active=function(_, state)
            table.insert(calls, 'complete:' .. state)
        end,
        start_active=function(run)
            table.insert(calls, 'start')
            run.state = 'running'
        end,
        activate_next=function() table.insert(calls, 'activate_next') end,
        cancel_timeout=function(id)
            table.insert(calls, 'cancel_timeout:' .. tostring(id))
        end,
        now_ms=function() return 120 end,
        current_frame=function() return 45 end,
        assemble_scheduler=function(_, run, callbacks)
            local scheduler_module = {
                new=function(_, scheduler_dependencies)
                    return {dependencies=scheduler_dependencies, owner={}}
                end,
                bind=function(scheduler, thread) scheduler.thread = thread end,
                cancel=function() table.insert(calls, 'cancel_scheduler') end,
                owns_yield=function() return true end,
            }
            local scheduler = scheduler_module.new(run, {
                on_complete=callbacks.on_complete})
            run.scheduler_module, run.scheduler = scheduler_module, scheduler
            return scheduler_module, scheduler
        end,
        execute_suite=function() table.insert(calls, 'execute') end,
    }
    for name, value in pairs(overrides or {}) do values[name] = value end
    return values
end

---Creates the minimum cleanable run state used by lifecycle specs.
---@param calls string[]
---@return table
local function cleanable_run(calls)
    local registry = {failures={}}
    return {
        run_id='run', generation=2, state='running', terminal=false,
        counts={errors=0}, totals={failures=0, errors=0},
        output_lines={}, failure_details={}, recorded_cleanup_failures={},
        cleanup_registry=registry,
        cleanup_module={
            run=function(_, reason)
                table.insert(calls, 'cleanup:' .. reason)
                return true
            end,
            pending_count=function() return 0 end,
        },
    }
end

describe('host run lifecycle', function()
    it('cleans owned resources in order and confirms the drained state', function()
        local calls = {}
        local lifecycle = module.new(dependencies(calls))
        local run = cleanable_run(calls)
        run.focus_lifecycle={clear=function()
            table.insert(calls, 'clear_focus')
        end}
        run.scheduler_module={cancel=function()
            table.insert(calls, 'cancel_scheduler')
        end}
        run.scheduler={owner={}}
        run.scheduled_timeout_id=9
        run.mount_cleanup_probe=function()
            return {active_screen_count=0, subject_count=0}
        end

        assert.is_true(lifecycle.clean(run, 'complete'))
        assert.same({'clear_focus', 'cancel_scheduler', 'cancel_timeout:9',
            'cleanup:complete', 'publish:cleanup_finished'}, calls)
        assert.is_true(run.cleanup_confirmed)
        assert.is_true(run.mount_cleanup_verified)
    end)

    it('ignores stale finalization and finalizes a current successful run', function()
        local calls = {}
        local lifecycle = module.new(dependencies(calls))
        local run = cleanable_run(calls)
        lifecycle.finalize({active_run_id='other', runs={run=run}}, run,
            true)
        assert.same({}, calls)

        lifecycle.finalize({active_run_id='run', runs={run=run}}, run, true)
        assert.same({'begin_cleanup', 'cancel_timeout:nil',
            'cleanup:suite completion', 'publish:cleanup_finished',
            'complete:passed', 'activate_next'}, calls)
        assert.equals(120, run.finished_ms)
        assert.equals(45, run.finished_frame)
    end)

    it('starts a current run and hands terminal completion to cleanup', function()
        local calls = {}
        local lifecycle = module.new(dependencies(calls))
        local run = cleanable_run(calls)
        run.state='starting'
        run.options={}
        local registry={active_run_id='run', runs={run=run}}

        lifecycle.begin('package', 'project', registry, run)

        assert.same({'start', 'execute', 'begin_cleanup',
            'cancel_scheduler', 'cancel_timeout:nil',
            'cleanup:suite completion', 'publish:cleanup_finished',
            'complete:passed', 'activate_next'}, calls)
        assert.equals(120, run.started_ms)
        assert.equals(45, run.started_frame)
    end)

    it('aborts an expired run through cleanup before terminal handoff', function()
        local calls = {}
        local lifecycle = module.new(dependencies(calls))
        local run = cleanable_run(calls)

        assert.equals(run, lifecycle.abort(
            {active_run_id='run', runs={run=run}}, run, 'expired'))
        assert.same({'publish:run_aborted', 'begin_cleanup',
            'cancel_timeout:nil', 'cleanup:expired',
            'publish:cleanup_finished', 'complete:aborted',
            'activate_next'}, calls)
        assert.equals('ABORTED expired', run.output_lines[1])
    end)

    it('hands host and cleanup failures to the service quarantine decision',
            function()
        local calls = {}
        local completion
        local lifecycle = module.new(dependencies(calls, {
            complete_active=function(_, state, cleanup_ok, reason)
                completion={state=state, cleanup_ok=cleanup_ok, reason=reason}
                table.insert(calls, 'complete:' .. state)
            end,
        }))
        local run = cleanable_run(calls)
        run.cleanup_module.run=function(registry)
            table.insert(registry.failures, {
                id=1, name='restore', reason='suite completion',
                message='failed'})
            return false
        end

        lifecycle.finalize({active_run_id='run', runs={run=run}}, run,
            false, 'suite crashed')

        assert.equals(2, run.counts.errors)
        assert.equals(2, run.totals.errors)
        assert.equals('suite crashed', run.host_error)
        assert.equals('complete:failed', calls[#calls - 1])
        assert.is_false(run.cleanup_confirmed)
        assert.same({state='failed', cleanup_ok=false,
            reason='suite completion'}, completion)
    end)

    it('maps Busted assertion failures to a failed terminal state', function()
        local calls = {}
        local lifecycle = module.new(dependencies(calls))
        local run = cleanable_run(calls)
        run.totals.failures = 1

        lifecycle.finalize({active_run_id='run', runs={run=run}}, run, true)

        assert.equals('complete:failed', calls[#calls - 1])
        assert.equals(0, run.totals.errors)
    end)
end)
