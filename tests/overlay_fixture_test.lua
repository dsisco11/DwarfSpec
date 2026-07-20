-- Unit contracts for safe explicitly imported overlay fixture staging.

local cleanup = assert(loadfile(
    'tests/automation/support/cleanup.lua'))()
local overlay_fixture = assert(loadfile(
    'tests/automation/support/overlay_fixture.lua'))()

describe('DwarfSpec overlay fixtures', function()
    local files
    local rescans
    local descriptor
    local services

    before_each(function()
        files = {
            ['project/tests/support/probe.definition.lua']='definition',
            ['project/custom/probe_overlay.lua']='OVERLAY_WIDGETS = {}',
        }
        rescans = 0
        descriptor = {
            project_root='project',
            package_root='.',
            filesystem={
                isfile=function(path)
                    return files[path:gsub('\\', '/')] ~= nil
                end,
            },
        }
        services = {
            destination_directory='game/hack/scripts/gui',
            isfile=function(path)
                return files[path:gsub('\\', '/')] ~= nil
            end,
            loadfile=function()
                return function()
                    return {name='probe', source='custom/probe_overlay.lua'}
                end
            end,
            read_file=function(path)
                return assert(files[path:gsub('\\', '/')])
            end,
            write_file=function(path, contents)
                files[path:gsub('\\', '/')] = contents
            end,
            remove_file=function(path)
                files[path:gsub('\\', '/')] = nil
                return true
            end,
            rescan=function() rescans = rescans + 1 end,
        }
    end)

    it('stages a unique safe name and removes it through LIFO cleanup',
            function()
        local registry = cleanup.new({})
        local staged = overlay_fixture.stage(descriptor,
            'tests/support/probe.definition.lua', 'run-1', cleanup, registry,
            services)

        assert.equals('dwarfspec_run-1_probe', staged.script_name)
        assert.equals('OVERLAY_WIDGETS = {}',
            files['game/hack/scripts/gui/dwarfspec_run-1_probe.lua'])
        assert.equals(1, rescans)
        assert.is_true(cleanup.run(registry, 'test completion'))
        assert.is_nil(files[
            'game/hack/scripts/gui/dwarfspec_run-1_probe.lua'])
        assert.equals(2, rescans)
    end)

    it('refuses to overwrite an existing staged path', function()
        files['game/hack/scripts/gui/dwarfspec_run-1_probe.lua'] = 'owned'
        assert.has_error(function()
            overlay_fixture.stage(descriptor,
                'tests/support/probe.definition.lua', 'run-1', cleanup,
                cleanup.new({}), services)
        end, 'refusing to overwrite an existing overlay fixture: ' ..
            'game/hack/scripts/gui' .. package.config:sub(1, 1) ..
            'dwarfspec_run-1_probe.lua')
    end)

    it('removes a partial stage when the initial rescan fails', function()
        services.rescan = function()
            rescans = rescans + 1
            if rescans == 1 then error('deliberate rescan failure') end
        end
        local ok, message = pcall(function()
            overlay_fixture.stage(descriptor,
                'tests/support/probe.definition.lua', 'run-2', cleanup,
                cleanup.new({}), services)
        end)
        assert.is_false(ok)
        assert.matches('overlay fixture rescan failed:', message, 1, true)
        assert.is_nil(files[
            'game/hack/scripts/gui/dwarfspec_run-2_probe.lua'])
        assert.equals(2, rescans)
    end)
end)
