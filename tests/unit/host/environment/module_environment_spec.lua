local module = require('dwarfspec.host.environment.module_environment')

describe('host module environment', function()
    it('prepends pinned paths, clears caches, and installs native adapters',
            function()
        local original_path = package.path
        local original_preload_system = package.preload.system
        local original_preload_lfs = package.preload.lfs
        local original_loaded_system = package.loaded.system
        local original_loaded_lfs = package.loaded.lfs
        local cleared = false
        local loaded = {}
        local service = module.new({
            clear_dependencies=function() cleared = true end,
            load_module=function(root, name)
                table.insert(loaded, {root, name})
                return {name=name}
            end,
        })

        local ok, entries = pcall(service.configure, 'package', 'pinned')
        local configured_path = package.path
        local system, lfs = package.loaded.system, package.loaded.lfs
        package.path = original_path
        package.preload.system = original_preload_system
        package.preload.lfs = original_preload_lfs
        package.loaded.system = original_loaded_system
        package.loaded.lfs = original_loaded_lfs
        assert.is_true(ok)
        assert.is_true(cleared)
        assert.equals(entries[1], configured_path:match('^[^;]+'))
        assert.same({
            {'package', 'dwarfspec.host.environment.system_adapter'},
            {'package', 'dwarfspec.host.environment.lfs_adapter'},
        }, loaded)
        assert.equals('dwarfspec.host.environment.system_adapter',
            system.name)
        assert.equals('dwarfspec.host.environment.lfs_adapter', lfs.name)
    end)

    it('prioritizes protected and project paths, then evicts project modules on restore', function()
        local separator = package.config:sub(1, 1)
        local runtime = {path='original/?.lua', loaded={existing=true}}
        runtime.searchpath = function(name, path)
            if name == 'project_module' and path:find('project', 1, true) then
                return 'project/project_module.lua'
            end
            return nil
        end
        local service = module.new({clear_dependencies=function() end,
            load_module=function() return {} end})
        local restore, audit = service.configure_project('project',
            {'protected' .. separator .. '?.lua'}, runtime)
        assert.matches('^protected', runtime.path)
        assert.matches('project', runtime.path)
        runtime.loaded.project_module = {}
        restore()
        restore()
        assert.equals('original/?.lua', runtime.path)
        assert.is_nil(runtime.loaded.project_module)
        assert.is_true(audit.restored)
        assert.is_true(audit.path_restored)
        assert.same({'project_module'}, audit.evicted_modules)
    end)

    it('rejects incomplete runtime package adapters', function()
        local service = module.new({clear_dependencies=function() end,
            load_module=function() return {} end})
        assert.has_error(function()
            service.configure_project('project', {}, {path='', loaded={}})
        end, 'runtime package must provide path, loaded, and searchpath')
    end)
end)
