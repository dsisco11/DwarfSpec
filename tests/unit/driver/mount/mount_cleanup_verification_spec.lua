-- Direct contracts for mount teardown and cleanup evidence.

local cleanup = require(
    'dwarfspec.driver.mount.mount_cleanup_verification')
local cleanup_registry = require('dwarfspec.host.execution.cleanup')

---Creates one mounted resource graph and its cleanup event log.
---@return table, table, string[]
local function make_mount()
    local events = {}
    local screen = {active=true}
    local source = {adapter={cleanup=function()
        table.insert(events, 'source')
    end}}
    local target = {cleanup=function()
        table.insert(events, 'pointer')
    end}
    local mount = {
        id=3,
        alive=true,
        cleaned=false,
        root={},
        host_screen=screen,
        interaction_target=target,
        subject_source=source,
        subject_sources={[source]=true},
        adapter={
            unmount=function()
                screen.active = false
                table.insert(events, 'unmount')
            end,
            settle=function() table.insert(events, 'settle') end,
        },
        selected_subjects=setmetatable({}, {__mode='k'}),
        owned_views=setmetatable({}, {__mode='k'}),
        cleanup_entries={},
    }
    local context = {
        current=mount,
        subject_mounts=setmetatable({}, {__mode='k'}),
        subject_module={release=function()
            table.insert(events, 'subject')
        end},
        view_mounts=setmetatable({}, {__mode='k'}),
        owned_screens=setmetatable({[screen]=true}, {__mode='k'}),
        owned_screen_count=1,
        borrowed_native_screen_count=0,
        native_attachment_count=0,
        native_screen_dismissal_count=0,
    }
    return cleanup.new(context), mount, events
end

describe('mount cleanup verification', function()
    it('detaches resources in the established teardown order', function()
        local context, mount, events = make_mount()
        local selected = {}
        mount.selected_subjects[selected] = true
        context.subject_mounts[selected] = mount.id
        context:cleanup_mount(mount)
        assert.same({'unmount', 'settle', 'subject', 'source', 'pointer'}, events)
        assert.is_nil(context.current)
        assert.is_false(mount.alive)
    end)

    it('preserves an actual borrowed mounted screen',
            function()
        local context, mount = make_mount()
        local borrowed = {active=true, dismissals=0}
        mount.host_screen = nil
        mount.pinned_screen = borrowed
        mount.adapter = nil
        mount.interaction_target = {
            cleanup=function()
                assert.is_true(borrowed.active)
                assert.equals(0, borrowed.dismissals)
            end,
        }
        mount.attachment_counted = true
        context.borrowed_native_screen_count = 1
        context.owned_screens = setmetatable({}, {__mode='k'})
        context.owned_screen_count = 0
        context:cleanup_mount(mount)
        assert.equals(0, context.borrowed_native_screen_count)
        assert.equals(0, context.owned_screen_count)
        assert.is_true(borrowed.active)
        assert.equals(0, borrowed.dismissals)
    end)

    it('aggregates multiple teardown failures after continuing cleanup', function()
        local context, mount, events = make_mount()
        mount.adapter.unmount = function()
            table.insert(events, 'unmount')
            error('dismissal failed', 0)
        end
        mount.interaction_target.cleanup = function()
            table.insert(events, 'pointer')
            error('pointer restore failed', 0)
        end
        local ok, failure = pcall(context.cleanup_mount, context, mount)
        assert.is_false(ok)
        assert.matches('dismissal failed', failure, 1, true)
        assert.matches('pointer restore failed', failure, 1, true)
        assert.same({'unmount', 'settle', 'source', 'pointer'}, events)
        assert.is_nil(context.current)
    end)

    it('restores render observation before lower native cleanup layers',
            function()
        local events = {}
        local registry = cleanup_registry.new({run_id='cleanup-order'})
        local mount = {
            id=8,
            cleaned=false,
            selected_subjects=setmetatable({}, {__mode='k'}),
            cleanup_entries={},
        }
        local context = {
            cleanup_module=cleanup_registry,
            cleanup_registry=registry,
            current=mount,
            subject_mounts=setmetatable({}, {__mode='k'}),
            subject_module={release=function() end},
        }
        function context:push_cleanup(value, name, action)
            local entry = cleanup_registry.push(registry, name, action)
            table.insert(value.cleanup_entries, entry)
            return entry
        end
        cleanup_registry.push(registry, 'lower cleanup', function()
            table.insert(events, 'lower')
        end)
        local service = cleanup.new(context)
        service:register_subject_release(mount)
        service:register_observer_restore(mount, function()
            table.insert(events, 'observer')
        end)
        assert.is_true(cleanup_registry.run(registry, 'cleanup order'))
        assert.same({'observer', 'lower'}, events)
    end)

    it('is idempotent and reports exact verified state', function()
        local context, mount, events = make_mount()
        context:cleanup_mount(mount)
        context:cleanup_mount(mount)
        assert.equals(4, #events)
        assert.same({
            current_mount_id=nil,
            active_screen_count=0,
            tracked_screen_count=0,
            owned_screen_count=0,
            borrowed_native_screen_count=0,
            native_attachment_count=0,
            native_screen_dismissal_count=0,
            subject_count=0,
        }, context:cleanup_state())
    end)
end)
