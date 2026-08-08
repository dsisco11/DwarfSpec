local module = require('dwarfspec.host.execution.run_assembly')

describe('host run assembly', function()
    it('initializes run ownership and generation-guarded publication', function()
        local published
        local cleanup = {new=function(run, active)
            return {run=run, active=active}
        end}
        local run = {run_id='run', generation=4, lease_check_frames=2}
        module.initialize(run, 'package', 'project', {seed=7}, {
            ds_factory={new=function() end},
            load_module=function(root, name)
                assert.equals('package', root)
                if name == 'dwarfspec.host.execution.cleanup' then
                    return cleanup
                elseif name == 'dwarfspec.driver.command.resource_dependency_index' then
                    return {new=function(service_run_id)
                        return {service_run_id=service_run_id}
                    end}
                elseif name == 'dwarfspec.driver.cleanup.cleanup_registration_service' then
                    return {new=function(options)
                        return {service_run_id=options.service_run_id,
                            resource_index=options.resource_index,
                            finalize_owner=function() return true end}
                    end}
                end
                assert.equals('dwarfspec.host.execution.cleanup_owner_lifecycle',
                    name)
                return {new=function(service_run_id, cleanup_service)
                    return {service_run_id=service_run_id,
                        cleanup_service=cleanup_service}
                end}
            end,
            now_ms=function() return 100 end,
            current_frame=function() return 20 end,
            is_active=function() return true end,
            create_event_publisher=function(owned_run, dependencies)
                return {now_ms=dependencies.now_ms,
                    publish=function(kind, payload)
                        return dependencies.publish_active_event(
                            owned_run.run_id, owned_run.generation,
                            kind, payload)
                    end}
            end,
            publish_active_event=function(run_id, generation, kind, payload)
                published = {run_id, generation, kind, payload}
            end,
        })
        assert.equals('package', run.package_root)
        assert.equals('project', run.project_root)
        assert.equals(100, run.created_ms)
        assert.equals(20, run.created_frame)
        assert.equals(cleanup, run.cleanup_module)
        assert.is_true(run.cleanup_registry.active())
        assert.equals('run', run.resource_dependency_index.service_run_id)
        assert.equals('run', run.cleanup_owner_lifecycle.service_run_id)
        run.event_publisher.publish('started', {value=1})
        assert.same({'run', 4, 'started', {value=1}}, published)
    end)

    it('rejects invalid lease scheduling configuration', function()
        assert.has_error(function()
            module.initialize({lease_check_frames=0}, 'p', 'r', {}, {
                ds_factory={new=function() end},
                load_module=function() return {new=function() return {} end} end,
                now_ms=function() return 1 end,
                current_frame=function() return 1 end,
                is_active=function() return true end,
                create_event_publisher=function() return {} end,
                publish_active_event=function() end,
            })
        end, 'lease check interval must be a positive integer')
    end)

    it('rejects assembly without the injected root ds factory', function()
        assert.has_error(function()
            module.initialize({lease_check_frames=1}, 'p', 'r', {}, {
                load_module=function()
                    return {new=function() return {} end}
                end,
                now_ms=function() return 1 end,
                current_frame=function() return 1 end,
            })
        end, 'run assembly requires an injected dwarfspec.ds factory')
    end)

    it('creates a scheduler with the supplied timing and completion adapters',
            function()
        local received
        local scheduler_module = {new=function(run, dependencies)
            received = {run=run, dependencies=dependencies}
            return {id='scheduler'}
        end}
        local run = {}
        local callbacks = {
            is_current=function() return true end,
            schedule_frames=function() end,
            schedule_ticks=function() end,
            cancel_timeout=function() end,
            now_ms=function() return 1 end,
            diagnostics=function() return {} end,
            on_complete=function() end,
        }

        local returned_module, scheduler = module.create_scheduler(
            'package', run, {
                load_scheduler=function(root)
                    assert.equals('package', root)
                    return scheduler_module
                end,
                is_current=callbacks.is_current,
                schedule_frames=callbacks.schedule_frames,
                schedule_ticks=callbacks.schedule_ticks,
                cancel_timeout=callbacks.cancel_timeout,
                now_ms=callbacks.now_ms,
                diagnostics=callbacks.diagnostics,
                on_complete=callbacks.on_complete,
            })

        assert.equals(scheduler_module, returned_module)
        assert.equals(scheduler, run.scheduler)
        assert.equals(scheduler_module, run.scheduler_module)
        assert.equals(callbacks.on_complete,
            received.dependencies.on_complete)
    end)

    it('schedules activation and routes timer rejection to failure', function()
        local callback
        local failure
        local run = {options={defer_frames=3}}
        assert.equals(8, module.schedule_activation(run, {
            schedule_frames=function(delay, begin_run)
                assert.equals(3, delay)
                callback = begin_run
                return 8
            end,
            begin_run=function() end,
            fail_run=function(message) failure = message end,
        }))
        assert.equals(8, run.scheduled_timeout_id)
        assert.is_function(callback)
        assert.is_nil(failure)

        assert.is_nil(module.schedule_activation(run, {
            schedule_frames=function() return nil end,
            begin_run=function() end,
            fail_run=function(message) failure = message end,
        }))
        assert.equals('DFHack rejected the automation startup timer', failure)
    end)
end)
