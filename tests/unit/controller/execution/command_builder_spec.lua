-- Direct contracts for validated controller command construction.

local module = require('dwarfspec.controller.execution.command_builder')
local layout = require('dwarfspec.layout')
local ResultPolicy = require('dwarfspec.protocol.enums.result_policies')

---Creates representative command options for the source layout.
---@return table
local function options()
    local current = layout.current()
    return {
        package_root=current.package_root, host_scripts=current.host_scripts,
        project_root='tests/framework/minimal_project', repeat_count=2,
        startup_delay_frames=3, lease_timeout_ms=4000, lease_check_frames=5,
        test_glob='tests/**/*.lua', result_path='result.json',
        filters={'one', 'two'}, filter_out={'skip'}, names={'name'},
        tags={'tag'}, exclude_tags={'slow'}, identities={'tests/a/b.ds.lua'},
    }
end

describe('controller command builder', function()
    it('builds every host operation with exact identity and cursor values', function()
        local builder = module.new({fail=error, dependency_kind='dependency'})
        local value = options()
        assert.same({'lua', '-f', value.host_scripts.probe}, builder.probe(value))
        assert.same({
            'lua', '-f', value.host_scripts.bootstrap, 'run',
            '--project-root=tests/framework/minimal_project',
            '--repeat=2', '--defer-frames=3', '--lease-timeout-ms=4000',
            '--lease-check-frames=5', '--test-glob=tests/**/*.lua',
            '--lua-module-root=' .. builder.lua_module_root(value.package_root),
            '--result-policy=' .. ResultPolicy.FILE,
            '--result-path=result.json', '--filter=one', '--filter=two',
            '--filter-out=skip', '--name=name', '--tag=tag',
            '--exclude-tag=slow', '--spec=a/b.ds.lua',
        }, builder.bootstrap(value, 'run'))
        assert.same({'lua', '-f', value.host_scripts.status, 'run', 'owner', '7'},
            builder.poll(value, 'run', 'owner', 7))
        assert.same({'lua', '-f', value.host_scripts.run_query, 'show', 'run'},
            builder.query(value, 'show', 'run'))
        assert.same({'lua', '-f', value.host_scripts.scheduler_status},
            builder.scheduler_status(value))
        assert.same({'lua', '-f', value.host_scripts.acknowledge,
            'run', '2', 'owner', '7'},
            builder.acknowledge(value, 'run', 2, 'owner', 7))
        assert.same({'lua', '-f', value.host_scripts.abort, 'run'},
            builder.abort(value, 'run'))
        assert.same({'lua', '-f', value.host_scripts.recover, 'run', 'owner',
            '7', 'external runner recovery'},
            builder.recover(value, 'run', 'owner', 7))
        assert.same({'lua', '-f', value.host_scripts.abort, 'run', '', '7'},
            builder.recover(value, 'run', nil, 7))
        assert.same({'lua', '-f', value.host_scripts.recover_executor,
            'run', '2', '0', 'reason'},
            builder.recover_executor(value, 'run', 2, 'reason'))
    end)

    it('resolves and validates source and installed dependency layouts', function()
        local seen = {}
        local source = module.new({fail=error, dependency_kind='dependency',
            file_exists=function(path)
                table.insert(seen, path)
                return true
            end})
        assert.same('source-root', source.lua_module_root('source-root'))
        local value = options()
        value.package_root = 'source-root'
        assert.has_no.errors(function() source.validate_dependencies(value) end)
        assert.is_truthy(table.concat(seen, '\n'):match(
            'source%-root[/\\]busted[/\\]core%.lua'))
        assert.is_truthy(table.concat(seen, '\n'):find(
            value.host_scripts.bootstrap, 1, true))

        seen = {}
        local installed = module.new({fail=error,
            dependency_kind='dependency', file_exists=function(path)
                table.insert(seen, path)
                return not path:match('installed%-root[/\\]busted[/\\]core%.lua$')
            end})
        local installed_root = installed.lua_module_root('installed-root')
        assert.matches('installed%-root[/\\]%.luarocks[/\\]share[/\\]lua[/\\]%d+%.%d+$',
            installed_root)
        value.package_root = 'installed-root'
        local installed_scripts = {}
        for name in pairs(value.host_scripts) do
            installed_scripts[name] = 'installed-root/dwarfspec/host/entrypoints/' ..
                name .. '.lua'
        end
        value.host_scripts = installed_scripts
        assert.has_no.errors(function() installed.validate_dependencies(value) end)
        assert.is_truthy(table.concat(seen, '\n'):find(
            installed_root .. package.config:sub(1, 1) .. 'busted' ..
                package.config:sub(1, 1) .. 'init.lua', 1, true))
        assert.is_truthy(table.concat(seen, '\n'):find(
            installed_scripts.bootstrap, 1, true))
    end)

    it('rejects missing entrypoints and does not reinterpret unsafe values', function()
        local builder = module.new({fail=function(kind, message)
            error(kind .. ': ' .. message, 0)
        end, dependency_kind='dependency'})
        local value = options()
        value.host_scripts = setmetatable({bootstrap='missing-file'},
            {__index=value.host_scripts})
        assert.has_error(function() builder.validate_dependencies(value) end,
            'dependency: DwarfSpec dependency was not found: missing-file')
        value = options()
        value.filters={'a;rm'}
        assert.is_truthy(table.concat(builder.bootstrap(value, 'run'), '\n')
            :match('%-%-filter=a;rm'))
    end)
end)
