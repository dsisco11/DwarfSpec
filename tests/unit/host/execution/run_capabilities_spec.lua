local module = require('dwarfspec.host.execution.run_capabilities')

describe('host run capabilities', function()
    local function fixture(overrides)
        local calls = {}
        local scheduler = {identity='scheduler'}
        local cleanup_registry = {identity='cleanup'}
        local overlay_services = {
            destination_directory='df/hack/scripts/gui',
            config_path='df/dfhack-config/overlay.json',
            isfile=function(path)
                table.insert(calls, {'isfile', path})
                return path == 'project/tests/overlay.lua' or
                    path == 'existing'
            end,
            read_file=function(path)
                table.insert(calls, {'read_file', path})
                return 'contents:' .. path
            end,
            write_file=function(path, contents)
                table.insert(calls, {'write_file', path, contents})
                return 'written'
            end,
            remove_file=function(path)
                table.insert(calls, {'remove_file', path})
                return 'removed'
            end,
            rescan=function()
                table.insert(calls, {'rescan'})
                return 'rescanned'
            end,
            registered_names=function(script_name)
                table.insert(calls, {'registered_names', script_name})
                return {'gui/' .. script_name .. '.widget'}
            end,
            is_enabled=function(name)
                table.insert(calls, {'is_enabled', name})
                return name == 'enabled'
            end,
            disable=function(name)
                table.insert(calls, {'disable', name})
                return 'disabled'
            end,
        }
        local dependencies = {
            run_id='run-1',
            scheduler_module={
                wait_until=function(owner, description, query, options)
                    table.insert(calls, {
                        'wait_until', owner, description, options,
                    })
                    return query()
                end,
                wait_frames=function(owner, count)
                    table.insert(calls, {'wait_frames', owner, count})
                    return count
                end,
            },
            scheduler=scheduler,
            cleanup_module={
                mark=function(owner)
                    table.insert(calls, {'mark', owner})
                    return 7
                end,
                push=function(owner, name, action)
                    table.insert(calls, {'push', owner, name, action})
                    return {name=name}
                end,
                run_from=function(owner, marker, reason)
                    table.insert(calls, {
                        'run_from', owner, marker, reason,
                    })
                    return true, {}
                end,
            },
            cleanup_registry=cleanup_registry,
            recurring_operations={
                schedule=function(callback)
                    table.insert(calls, {'recurring_schedule', callback})
                    return 'opaque-handle'
                end,
                cancel=function(handle)
                    table.insert(calls, {'recurring_cancel', handle})
                end,
                is_scheduled=function(handle)
                    table.insert(calls, {'recurring_is_scheduled', handle})
                    return handle == 'opaque-handle'
                end,
                report_failure=function(message, trace)
                    table.insert(calls, {'recurring_failure', message, trace})
                    return true
                end,
            },
            project_module={
                relative_path=function(path)
                    assert.not_equals('../outside.lua', path)
                    return path:gsub('\\', '/')
                end,
                join=function(root, relative_path)
                    return root .. '/' .. relative_path
                end,
            },
            project={
                project_root='project',
                filesystem={isfile=overlay_services.isfile},
            },
            overlay_services=overlay_services,
        }
        for name, value in pairs(overrides or {}) do
            dependencies[name] = value
        end
        return dependencies, calls, scheduler, cleanup_registry
    end

    it('forwards narrow scheduling, cleanup, project, and overlay operations',
            function()
        local dependencies, calls, scheduler, cleanup_registry = fixture()
        local capabilities = module.new(dependencies)
        local action = function() end

        assert.equals('run-1', capabilities.run_id)
        assert.equals('ready', capabilities.scheduling.wait_until(
            'condition', function() return 'ready' end, {timeout_ms=10}))
        assert.equals(3, capabilities.scheduling.wait_frames(3))
        assert.equals(7, capabilities.cleanup.mark())
        assert.same({name='restore'},
            capabilities.cleanup.register('restore', action))
        local rollback_ok, failures =
            capabilities.cleanup.rollback(7, 'construction failed')
        assert.is_true(rollback_ok)
        assert.same({}, failures)
        assert.same({
            relative_path='tests/overlay.lua',
            absolute_path='project/tests/overlay.lua',
        }, capabilities.project.resolve_lua_source('tests\\overlay.lua'))

        assert.equals('df/hack/scripts/gui',
            capabilities.overlay.destination_directory)
        assert.equals('df/dfhack-config/overlay.json',
            capabilities.overlay.config_path)
        assert.is_true(capabilities.overlay.isfile('existing'))
        assert.equals('contents:file',
            capabilities.overlay.read_file('file'))
        assert.equals('written',
            capabilities.overlay.write_file('file', 'new'))
        assert.equals('removed', capabilities.overlay.remove_file('file'))
        assert.equals('rescanned', capabilities.overlay.rescan())
        assert.same({'gui/probe.widget'},
            capabilities.overlay.registered_names('probe'))
        assert.is_true(capabilities.overlay.is_enabled('enabled'))
        assert.equals('disabled', capabilities.overlay.disable('enabled'))

        assert.same({'wait_until', scheduler, 'condition', {timeout_ms=10}},
            calls[1])
        assert.same({'wait_frames', scheduler, 3}, calls[2])
        assert.same({'mark', cleanup_registry}, calls[3])
        assert.same({'push', cleanup_registry, 'restore', action}, calls[4])
        assert.same({'run_from', cleanup_registry, 7,
            'construction failed'}, calls[5])
        assert.equals('opaque-handle',
            capabilities.recurring.schedule(action))
        assert.is_true(capabilities.recurring.is_scheduled('opaque-handle'))
        capabilities.recurring.cancel('opaque-handle')
        assert.is_true(capabilities.recurring.report_failure('broken', 'trace'))
        assert.is_nil(capabilities.scheduler)
        assert.is_nil(capabilities.cleanup_registry)
        assert.is_nil(capabilities.project_environment)
        assert.is_nil(capabilities.service_registry)
    end)

    it('rejects invalid identity and incomplete host interfaces', function()
        local dependencies = fixture({run_id='../unsafe'})
        assert.has_error(function() module.new(dependencies) end,
            'run capabilities require a safe run id')

        dependencies = fixture()
        dependencies.scheduler_module.wait_frames = nil
        assert.has_error(function() module.new(dependencies) end,
            'run capabilities require scheduler.wait_frames()')

        dependencies = fixture()
        dependencies.overlay_services.rescan = nil
        assert.has_error(function() module.new(dependencies) end,
            'run capabilities require overlay service.rescan()')
    end)

    it('validates project Lua sources without exposing the environment',
            function()
        local dependencies = fixture()
        local capabilities = module.new(dependencies)

        assert.has_error(function()
            capabilities.project.resolve_lua_source('tests/readme.txt')
        end, 'project Lua source must name one Lua module: tests/readme.txt')
        assert.has_error(function()
            capabilities.project.resolve_lua_source('tests/missing.lua')
        end, 'project Lua source was not found: tests/missing.lua')
        assert.has_error(function()
            capabilities.project.resolve_lua_source(
                'tests/readme.txt', 'overlay registration')
        end, 'overlay registration source must name one Lua module: ' ..
            'tests/readme.txt')
    end)
end)
