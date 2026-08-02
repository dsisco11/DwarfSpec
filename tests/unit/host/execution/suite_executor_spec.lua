local module = require('dwarfspec.host.execution.suite_executor')

describe('host suite executor', function()
    it('wires Busted callbacks, discovery, repeats, and cleanup handoff',
            function()
        local calls = {}
        local pushed
        local executed
        local busted={
            export=function(name) table.insert(calls, 'export:' .. name) end,
            publish=function(event)
                table.insert(calls, 'publish:' .. event[1])
            end,
        }
        local lifecycle={suite_entry=function() end,
            suite_exit=function() end, test_start=function() end,
            example_entry=function() end, example_exit=function() end}
        local run={
            run_id='run-1',
            options={specs={'selected_spec.lua'}, repeat_count=3, seed=9},
            cleanup_registry={}, event_publisher={},
            cleanup_module={push=function(_, name, callback)
                pushed={name=name, callback=callback}
            end},
        }
        local project={}
        local capabilities={run_id='run-1'}
        local capability_options
        local forwarded_capabilities
        local dependencies={
            configure_dependencies=function()
                table.insert(calls, 'dependencies')
                return {'protected'}
            end,
            new_busted=function() table.insert(calls, 'busted'); return busted end,
            load_module=function(_, name)
                if name:match('project_environment') then
                    return {new=function() return project end}
                elseif name:match('extensions') then
                    return {load=function() return {settings={}} end}
                elseif name:match('busted_lifecycle_adapter') then
                    return {install=function(_, options)
                        assert.equals(lifecycle.suite_entry,
                            options.on_suite_entry)
                        assert.equals(lifecycle.suite_exit,
                            options.on_suite_exit)
                        assert.equals(lifecycle.test_start,
                            options.on_test_start)
                    end}
                elseif name:match('base_screen_focus_guard') then
                    return {new=function() return {} end}
                end
                return {new=function()
                    table.insert(calls, 'output')
                end}
            end,
            filesystem={}, gui={},
            configure_project=function()
                table.insert(calls, 'project_environment')
                return function() end, {restored=false}
            end,
            new_run_capabilities=function(options)
                capability_options = options
                return capabilities
            end,
            create_overlay_services=function()
                return {identity='overlay-services'}
            end,
            ds_factory={new=function(_, _, _, _, _, _, _, _, value)
                forwarded_capabilities = value
                table.insert(calls, 'ds')
                return {}, function() end
            end},
            new_lifecycle=function() return lifecycle end,
            install_entry=function() table.insert(calls, 'entry') end,
            install_exit=function() table.insert(calls, 'exit') end,
            filter_options=function() return {filter='options'} end,
            install_filter=function(_, options)
                assert.same({filter='options'}, options)
                table.insert(calls, 'filter')
            end,
            new_loader=function() return function() end end,
            discover_tests=function(_, _, specs)
                assert.same({'selected_spec.lua'}, specs)
                table.insert(calls, 'discovery')
                return {'selected'}
            end,
            execute_busted=function(_, repeat_count, options)
                executed={repeat_count=repeat_count, options=options}
                table.insert(calls, 'execute')
            end,
        }

        module.execute('package', 'project', run, {}, {}, dependencies)

        assert.equals('project module environment', pushed.name)
        assert.is_function(pushed.callback)
        assert.same({'selected'}, run.discovered_files)
        assert.same({repeat_count=3,
            options={seed=9, shuffle=false, sort=true}}, executed)
        assert.equals('run-1', capability_options.run_id)
        assert.equals(project, capability_options.project)
        assert.equals(capabilities, forwarded_capabilities)
        assert.same({'dependencies', 'busted', 'project_environment', 'ds',
            'export:ds', 'entry', 'exit', 'output', 'filter', 'discovery',
            'execute', 'publish:exit'}, calls)
    end)

    it('propagates dependency setup failures before constructing Busted', function()
        local busted_created = false
        assert.has_error(function()
            module.execute('package', 'project', {
                options={repeat_count=1}, cleanup_module={},
                cleanup_registry={}}, {}, {}, {
                configure_dependencies=function()
                    error('dependency setup failed')
                end,
                new_busted=function()
                    busted_created = true
                    return {}
                end,
            })
        end, 'dependency setup failed')
        assert.is_false(busted_created)
    end)

    it('rejects an injected ds factory failure without running Busted', function()
        local run = {run_id='run-2',
            options={specs={'test.lua'}, repeat_count=1},
            cleanup_registry={}, cleanup_module={push=function() end},
            event_publisher={}}
        local project_module = {new=function() return {} end}
        local extensions_module = {load=function()
            return {settings={}}
        end}
        assert.has_error(function()
            module.execute('package', 'project', run, {}, {}, {
                configure_dependencies=function() return {} end,
                new_busted=function() return {export=function() end} end,
                load_module=function(_, name)
                    if name:match('project_environment') then return project_module end
                    return extensions_module
                end,
                filesystem={}, configure_project=function()
                    return function() end, {}
                end,
                new_run_capabilities=function() return {} end,
                create_overlay_services=function() return {} end,
                ds_factory={new=function() error('ds assembly failed') end},
            })
        end, 'ds assembly failed')
    end)

    it('propagates execution errors after registering environment cleanup',
            function()
        local cleanup_registered = false
        local exit_published = false
        local busted={export=function() end, publish=function()
            exit_published = true
        end}
        local project_module={new=function() return {} end}
        local lifecycle={suite_entry=function() end,
            suite_exit=function() end, test_start=function() end,
            example_entry=function() end, example_exit=function() end}
        assert.has_error(function()
            module.execute('package', 'project', {
                run_id='run-3',
                options={specs={'spec.lua'}, repeat_count=1},
                cleanup_registry={}, event_publisher={},
                cleanup_module={push=function()
                    cleanup_registered = true
                end}}, {}, {}, {
                configure_dependencies=function() return {} end,
                new_busted=function() return busted end,
                load_module=function(_, name)
                    if name:match('project_environment') then
                        return project_module
                    elseif name:match('extensions') then
                        return {load=function() return {settings={}} end}
                    elseif name:match('busted_lifecycle_adapter') then
                        return {install=function() end}
                    elseif name:match('base_screen_focus_guard') then
                        return {new=function() return {} end}
                    end
                    return {new=function() end}
                end,
                filesystem={}, gui={},
                configure_project=function()
                    return function() end, {}
                end,
                new_run_capabilities=function() return {} end,
                create_overlay_services=function() return {} end,
                ds_factory={new=function() return {}, function() end end},
                new_lifecycle=function() return lifecycle end,
                install_entry=function() end, install_exit=function() end,
                filter_options=function() return {} end,
                install_filter=function() end,
                new_loader=function() return function() end end,
                discover_tests=function() return {} end,
                execute_busted=function() error('Busted failed') end,
            })
        end, 'Busted failed')
        assert.is_true(cleanup_registered)
        assert.is_false(exit_published)
    end)
end)
