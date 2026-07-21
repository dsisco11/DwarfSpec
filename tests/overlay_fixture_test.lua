-- Unit contracts for reversible real-overlay registration staging.

local cleanup = assert(loadfile(
    'tests/automation/support/cleanup.lua'))()
local overlay_fixture = assert(loadfile(
    'tests/automation/support/overlay_fixture.lua'))()

describe('DwarfSpec overlay registration integration support', function()
    local files
    local rescans
    local descriptor
    local services
    local enabled
    local registered
    local fail_next_rescan
    local config_path

    ---Normalizes an injected filesystem path for the in-memory service.
    ---@param path string
    ---@return string
    local function normalize(path)
        return path:gsub('\\', '/')
    end

    before_each(function()
        config_path = 'game/dfhack-config/overlay.json'
        files = {
            ['project/tests/support/probe.definition.lua']='definition',
            ['project/custom/probe_overlay.lua']='OVERLAY_WIDGETS = {}',
            [config_path]='{"existing":{"enabled":true}}\n',
        }
        rescans = 0
        enabled = {}
        registered = {}
        fail_next_rescan = false
        descriptor = {
            project_root='project',
            package_root='.',
            filesystem={
                isfile=function(path)
                    return files[normalize(path)] ~= nil
                end,
            },
        }
        services = {
            destination_directory='game/hack/scripts/gui',
            config_path=config_path,
            isfile=function(path)
                return files[normalize(path)] ~= nil
            end,
            loadfile=function()
                return function()
                    return {name='probe', source='custom/probe_overlay.lua'}
                end
            end,
            read_file=function(path)
                return assert(files[normalize(path)])
            end,
            write_file=function(path, contents)
                files[normalize(path)] = contents
            end,
            remove_file=function(path)
                files[normalize(path)] = nil
                return true
            end,
            rescan=function()
                rescans = rescans + 1
                if fail_next_rescan then
                    fail_next_rescan = false
                    error('deliberate rescan failure')
                end
                registered = {}
                local script =
                    'game/hack/scripts/gui/dwarfspec_run-1_probe.lua'
                if files[script] then
                    registered[1] =
                        'gui/dwarfspec_run-1_probe.probe'
                end
            end,
            registered_names=function()
                local names = {}
                for _, name in ipairs(registered) do
                    table.insert(names, name)
                end
                return names
            end,
            is_enabled=function(name) return not not enabled[name] end,
            disable=function(name)
                enabled[name] = false
                files[config_path] = '{"test":"disabled"}\n'
            end,
        }
    end)

    it('restores script, registration, enablement, and exact configuration',
            function()
        local registry = cleanup.new({})
        local staged = overlay_fixture.stage(descriptor,
            'tests/support/probe.definition.lua', 'run-1', cleanup, registry,
            services)
        local registered_name = 'gui/dwarfspec_run-1_probe.probe'

        assert.equals('dwarfspec_run-1_probe', staged.script_name)
        assert.same({registered_name}, staged.registered_names)
        assert.equals('OVERLAY_WIDGETS = {}',
            files['game/hack/scripts/gui/dwarfspec_run-1_probe.lua'])
        assert.equals(1, rescans)

        enabled[registered_name] = true
        files[config_path] = '{"test":"mutated"}\n'
        assert.is_true(cleanup.run(registry, 'test completion'))

        assert.is_nil(files[
            'game/hack/scripts/gui/dwarfspec_run-1_probe.lua'])
        assert.equals('{"existing":{"enabled":true}}\n',
            files[config_path])
        assert.same({}, registered)
        assert.is_false(enabled[registered_name])
        assert.same({
            complete=true,
            script_removed=true,
            config_restored=true,
            registrations_removed=true,
            failures={},
        }, staged.cleanup_state)
        assert.equals(2, rescans)
    end)

    it('refuses to overwrite an existing staged path', function()
        files['game/hack/scripts/gui/dwarfspec_run-1_probe.lua'] = 'owned'
        assert.has_error(function()
            overlay_fixture.stage(descriptor,
                'tests/support/probe.definition.lua', 'run-1', cleanup,
                cleanup.new({}), services)
        end, 'refusing to overwrite an existing overlay registration ' ..
            'script: game/hack/scripts/gui' .. package.config:sub(1, 1) ..
            'dwarfspec_run-1_probe.lua')
    end)

    it('removes a partial stage when the initial rescan fails', function()
        fail_next_rescan = true
        local ok, message = pcall(function()
            overlay_fixture.stage(descriptor,
                'tests/support/probe.definition.lua', 'run-1', cleanup,
                cleanup.new({}), services)
        end)
        assert.is_false(ok)
        assert.matches('overlay registration staging failed:', message,
            1, true)
        assert.matches('deliberate rescan failure', message, 1, true)
        assert.is_nil(files[
            'game/hack/scripts/gui/dwarfspec_run-1_probe.lua'])
        assert.equals('{"existing":{"enabled":true}}\n',
            files[config_path])
        assert.equals(2, rescans)
    end)

    it('does not delete a staged path whose contents changed', function()
        local registry = cleanup.new({})
        local staged = overlay_fixture.stage(descriptor,
            'tests/support/probe.definition.lua', 'run-1', cleanup, registry,
            services)
        files['game/hack/scripts/gui/dwarfspec_run-1_probe.lua'] =
            'replacement contents'
        files[config_path] = '{"test":"mutated"}\n'

        local ok, failures = cleanup.run(registry, 'test completion')

        assert.is_false(ok)
        assert.matches('refusing to remove a modified overlay registration',
            failures[1].message, 1, true)
        assert.equals('replacement contents', files[
            'game/hack/scripts/gui/dwarfspec_run-1_probe.lua'])
        assert.equals('{"existing":{"enabled":true}}\n',
            files[config_path])
        assert.is_false(staged.cleanup_state.complete)
        assert.is_false(staged.cleanup_state.script_removed)
        assert.is_true(staged.cleanup_state.config_restored)
        assert.is_false(staged.cleanup_state.registrations_removed)
    end)

    it('removes a configuration file created during registration testing',
            function()
        files[config_path] = nil
        local registry = cleanup.new({})
        local staged = overlay_fixture.stage(descriptor,
            'tests/support/probe.definition.lua', 'run-1', cleanup, registry,
            services)
        files[config_path] = '{"test":"created"}\n'

        assert.is_true(cleanup.run(registry, 'test completion'))
        assert.is_nil(files[config_path])
        assert.is_true(staged.cleanup_state.config_restored)
    end)
end)
