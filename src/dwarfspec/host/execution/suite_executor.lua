-- Busted suite execution for one active host run.

local M = {}

---Executes one configured suite synchronously in its owner coroutine.
---@param package_root string
---@param project_root string
---@param run table
---@param scheduler_module table
---@param scheduler table
---@param dependencies table
function M.execute(package_root, project_root, run, scheduler_module,
        scheduler, dependencies)
    local dependency_entries = dependencies.configure_dependencies(
        package_root, run.options.lua_module_root)
    local busted = dependencies.new_busted()
    local project_module = dependencies.load_module(package_root,
        'dwarfspec.host.environment.project_environment')
    local project = project_module.new(project_root, package_root,
        dependencies.filesystem)
    local extensions_module = dependencies.load_module(package_root,
        'dwarfspec.host.environment.extensions')
    local restore_modules, module_audit = dependencies.configure_project(
        project_root, dependency_entries)
    run.module_environment_audit = module_audit
    run.cleanup_module.push(run.cleanup_registry,
        'project module environment', restore_modules)
    local extensions = extensions_module.load(project)
    local specs = run.options.specs or {}
    if #specs == 0 then
        local discovery = extensions.settings.discovery or {}
        specs = project_module.discover_specs(project,
            run.options.test_glob or discovery.test_glob)
    end

    local run_capabilities = dependencies.new_run_capabilities({
        run_id=run.run_id,
        scheduler_module=scheduler_module,
        scheduler=scheduler,
        cleanup_module=run.cleanup_module,
        cleanup_registry=run.cleanup_registry,
        project_module=project_module,
        project=project,
        overlay_services=dependencies.create_overlay_services(),
    })
    local ds, reset = dependencies.ds_factory.new(package_root, project,
        scheduler_module, scheduler, run.cleanup_module,
        run.cleanup_registry, extensions, nil, run_capabilities)
    busted.export('ds', ds)
    local lifecycle_adapter = dependencies.load_module(package_root,
        'dwarfspec.host.execution.busted_lifecycle_adapter')
    local guard_factory = dependencies.load_module(package_root,
        'dwarfspec.host.diagnostics.base_screen_focus_guard')
    local lifecycle = dependencies.new_lifecycle(
        run, reset, guard_factory.new(dependencies.gui))
    run.focus_lifecycle = lifecycle
    lifecycle_adapter.install(busted, {project_root=project_root,
        on_suite_entry=lifecycle.suite_entry,
        on_suite_exit=lifecycle.suite_exit,
        on_test_start=lifecycle.test_start})
    dependencies.install_entry(lifecycle_adapter, busted, lifecycle)
    dependencies.install_exit(lifecycle_adapter, busted, lifecycle)

    dependencies.load_module(package_root,
        'dwarfspec.host.execution.output_handler').new(
            busted, run, run.event_publisher)
    dependencies.install_filter(busted,
        dependencies.filter_options(run.options))
    local loader = dependencies.new_loader(busted)
    run.discovered_files = dependencies.discover_tests(
        project_root, loader, specs)
    busted.randomize, busted.sort, busted.randomseed =
        false, true, run.options.seed
    dependencies.execute_busted(busted, run.options.repeat_count, {
        seed=run.options.seed, shuffle=false, sort=true})
    busted.publish({'exit'})
end

return M
