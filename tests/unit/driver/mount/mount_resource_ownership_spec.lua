-- Direct contracts for mount allocation and ownership.

local cleanup = require('dwarfspec.host.execution.cleanup')
local ownership = require(
    'dwarfspec.driver.mount.mount_resource_ownership')
local cleanup_verification = require(
    'dwarfspec.driver.mount.mount_cleanup_verification')

---Creates one ownership context with a minimal owned component adapter.
---@return table, table, table
local function make_context()
    local registry = cleanup.new({run_id='ownership-test'})
    local events = {}
    local adapter = {
        mount=function(_, mount, prepared, register_cleanup)
            register_cleanup('component resource', function()
                table.insert(events, 'resource')
            end)
            mount.render_tracker.completed = true
            return {
                root=prepared.component,
                host_screen={active=true},
                interaction_target={
                    assert_current=function() return true end,
                    native_screen=function() return {} end,
                    invalidate=function() return true end,
                    cleanup=function() return true end,
                },
                subject_source={adapter={root=function()
                    return prepared.component
                end}},
            }
        end,
        unmount=function() table.insert(events, 'unmount') end,
    }
    local context = {
        run=registry.run,
        cleanup_module=cleanup,
        cleanup_registry=registry,
        boundary={
            classify=function()
                return {category='widget', input_form='instance', class={}}
            end,
            prepare=function(_, component)
                return {
                    category='widget', input_form='instance', class={},
                    component=component, options={viewport={}},
                }
            end,
        },
        adapter_factory=function() return adapter end,
        render_tracker_factory=function()
            return {
                capture=function() return 0 end,
                wait_after=function() return true end,
            }
        end,
        native_render_observer_factory=function() return function() end end,
        owned_screens=setmetatable({}, {__mode='k'}),
        owned_screen_count=0,
        borrowed_native_screen_count=0,
        native_attachment_count=0,
        subject_mounts=setmetatable({}, {__mode='k'}),
        view_mounts=setmetatable({}, {__mode='k'}),
        next_mount_id=0,
        subject_adapter=function(_, mount) return mount.subject_source.adapter end,
        refresh_views=function() end,
        root=function(self) return {mount_id=self.current.id} end,
        report_failure=function(_, _, _, failure) return tostring(failure) end,
        require_current=function(self)
            assert(self.current and self.current.alive,
                'current mount required')
            return self.current
        end,
        push_cleanup=function(self, mount, name, action)
            local entry = self.cleanup_module.push(
                self.cleanup_registry, name, action)
            table.insert(mount.cleanup_entries, entry)
            return entry
        end,
    }
    context.cleanup = cleanup_verification.new(context)
    return ownership.new(context), registry, events
end

describe('mount resource ownership', function()
    it('allocates owned mount identity and registers cleanup', function()
        local context, registry = make_context()
        local subject = context:mount({name='component'})
        assert.equals(1, subject.mount_id)
        assert.equals(1, context.current.id)
        assert.equals(2, cleanup.pending_count(registry))
    end)

    it('rejects a duplicate mount while preserving the current identity', function()
        local context = make_context()
        context:mount({})
        assert.has_error(function() context:mount({}) end,
            'DwarfSpec mount rejected because mount 1 is still current; ' ..
            'call ds.unmount() before creating another mount')
        assert.equals(1, context.current.id)
    end)

    it('hands explicit unmount to scoped LIFO cleanup', function()
        local context, registry, events = make_context()
        context:mount({})
        context:unmount()
        assert.same({'resource', 'unmount'}, events)
        assert.equals(0, cleanup.pending_count(registry))
    end)

    it('rolls construction back when activation fails', function()
        local context, registry = make_context()
        context.adapter_factory = function()
            return {
                mount=function() error('activation failed', 0) end,
                unmount=function() end,
            }
        end
        local ok, failure = pcall(context.mount, context, {})
        assert.is_false(ok)
        assert.matches('activation failed', failure, 1, true)
        assert.equals(0, cleanup.pending_count(registry))
    end)

    it('rolls back when mount cleanup registration fails', function()
        local context, registry = make_context()
        context.cleanup_module = {
            mark=cleanup.mark,
            run_from=cleanup.run_from,
            push=function() error('registration failed', 0) end,
        }
        local ok, failure = pcall(context.mount, context, {})
        assert.is_false(ok)
        assert.matches('registration failed', failure, 1, true)
        assert.is_nil(context.current)
        assert.equals(0, cleanup.pending_count(registry))
    end)

    it('tracks borrowed native mounts without owning their screens', function()
        local context, registry = make_context()
        local root = {}
        local source = {adapter={root=function() return root end}}
        local target = {
            assert_current=function() return true end,
            native_screen=function() return {} end,
            invalidate=function() return true end,
            cleanup=function() return true end,
        }
        local selected = context:mount_native_screen(function()
            return {
                root=root,
                pinned_screen={},
                interaction_target=target,
                subject_source=source,
            }
        end)
        assert.equals(1, selected.mount_id)
        assert.equals('borrowed', context.current.input_form)
        assert.equals(1, context.borrowed_native_screen_count)
        assert.equals(0, context.owned_screen_count)
        context:unmount()
        assert.equals(0, context.borrowed_native_screen_count)
        assert.equals(0, cleanup.pending_count(registry))
    end)
end)
