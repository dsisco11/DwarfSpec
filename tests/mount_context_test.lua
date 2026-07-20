-- Unit contracts for run-owned component mount orchestration.

local cleanup = assert(loadfile(
    'tests/automation/support/cleanup.lua'))()
local component = assert(loadfile('src/dwarfspec/component.lua'))()
local mount_context = assert(loadfile(
    'src/dwarfspec/mount_context.lua'))()
local render_tracker = assert(loadfile(
    'src/dwarfspec/render_tracker.lua'))()
local subject = assert(loadfile('src/dwarfspec/subject.lua'))()

---Creates a minimal callable class with DFHack defclass-compatible shape.
---@param parent table|nil
---@param initialize function|nil
---@return table
local function make_class(parent, initialize)
    local class = {ATTRS={}}
    class.__index = class
    class.super = parent
    setmetatable(class, {
        __index=parent,
        __call=function(self, attributes)
            attributes = attributes or {}
            local instance = {}
            for key, value in pairs(attributes) do instance[key] = value end
            setmetatable(instance, self)
            if initialize then initialize(instance, attributes) end
            return instance
        end,
    })
    return class
end

describe('DwarfSpec mount context', function()
    local Widget
    local OverlayWidget
    local ZScreen
    local TestWidget
    local registry
    local events
    local screens
    local context
    local fail_activation
    local invalid_result
    local fail_subject
    local fail_render

    before_each(function()
        Widget = make_class()
        OverlayWidget = make_class(Widget)
        ZScreen = make_class()
        TestWidget = make_class(Widget)
        registry = cleanup.new({run_id='mount-context-test'})
        events = {}
        screens = {}
        fail_activation = false
        invalid_result = false
        fail_subject = false
        fail_render = false
        local boundary = component.new({
            Widget=Widget,
            OverlayWidget=OverlayWidget,
            ZScreen=ZScreen,
        })
        context = mount_context.new({
            run=registry.run,
            boundary=boundary,
            cleanup_module=cleanup,
            cleanup_registry=registry,
            render_tracker_factory=function()
                return render_tracker.new({
                    wait_until=function(_, _, query)
                        return assert(query(), 'render did not complete')
                    end,
                }, {})
            end,
            subject_module={
                new=function(...)
                    if fail_subject then error('subject creation exploded') end
                    return subject.new(...)
                end,
            },
            adapter_factory=function(category)
                assert.equals('widget', category)
                return {
                    mount=function(_, mount, prepared, register_cleanup)
                        assert.equals(1, cleanup.pending_count(registry))
                        local screen = {active=true, name=prepared.component.name}
                        table.insert(screens, screen)
                        table.insert(events, 'mount:' .. screen.name)
                        register_cleanup('adapter resource ' .. screen.name,
                            function()
                                table.insert(events, 'resource:' .. screen.name)
                            end)
                        mount.adapter_screen = screen
                        if fail_activation then
                            error('activation exploded for ' .. screen.name)
                        end
                        if invalid_result then return 'invalid adapter result' end
                        if fail_render then
                            mount.render_tracker:failed(
                                'render exploded for ' .. screen.name)
                        else
                            mount.render_tracker:completed()
                        end
                        return {
                            root=prepared.component,
                            host_screen=screen,
                        }
                    end,
                    unmount=function(_, mount)
                        local screen = mount.adapter_screen
                        if screen then
                            screen.active = false
                            table.insert(events, 'unmount:' .. screen.name)
                        end
                    end,
                    settle=function(_, mount)
                        local screen = mount.adapter_screen
                        table.insert(events, 'settle:' ..
                            (screen and screen.name or 'unknown'))
                    end,
                }
            end,
        })
    end)

    after_each(function()
        assert.is_true(cleanup.run(registry, 'mount-context test teardown'))
        assert.is_nil(context.current)
        assert.equals(0, cleanup.pending_count(registry))
        for _, screen in ipairs(screens) do
            assert.is_false(screen.active)
        end
    end)

    it('owns the initial mount, host, private state, and root subject',
            function()
        local root_subject = context:mount(TestWidget, {name='first'})
        local mounted = context.current

        assert.equals(registry.run, context.run)
        assert.equals('first', root_subject:raw().name)
        assert.equals('first', mounted.root.name)
        assert.equals(screens[1], mounted.host_screen)
        assert.is_true(screens[1].active)
        assert.equals(1, mounted.render_tracker:generation())
        assert.is_nil(mounted.root.render_generation)
        assert.is_nil(mounted.root.mount_id)
        assert.is_nil(mounted.root.host_screen)
        assert.is_nil(mounted.root.cleanup_entries)
        assert.equals(2, #mounted.cleanup_entries)
        assert.equals(2, cleanup.pending_count(registry))
        assert.equals('k', getmetatable(context.subject_mounts).__mode)
        assert.equals('k', getmetatable(context.view_mounts).__mode)
        assert.equals('k', getmetatable(mounted.selected_subjects).__mode)
        assert.equals(mounted.id, context.view_mounts[mounted.root])
    end)

    it('refreshes descendant ownership and IDs after dynamic mutations',
            function()
        local original = {view_id='original', subviews={}}
        local nested = {view_id='nested', subviews={original}}
        context:mount(TestWidget, {
            name='dynamic-root',
            subviews={nested},
        })

        assert.equals(nested, context:find_view('nested'))
        assert.equals(original, context:find_view('original'))
        assert.equals(context.current.id, context.view_mounts[original])
        local original_subject = context:new_subject(original)
        local dynamic = {view_id='dynamic', subviews={}}

        context:mutate('add dynamic child', function()
            table.insert(nested.subviews, dynamic)
            context.current.render_tracker:completed()
        end)

        assert.equals(dynamic, context:find_view('dynamic'))
        assert.equals(context.current.id, context.view_mounts[dynamic])

        context:mutate('remove original child', function()
            table.remove(nested.subviews, 1)
            context.current.render_tracker:completed()
        end)

        assert.is_nil(context:find_view('original'))
        assert.is_nil(context.view_mounts[original])
        assert.has_error(function() original_subject:raw() end,
            'DwarfSpec subject raw access rejected subject ' ..
                'view_id="original" mount=1 because its view is outside ' ..
                'the current mount')
    end)

    it('waits for the render caused by each mutating operation', function()
        context:mount(TestWidget, {name='mutated'})

        local result = context:mutate('click', function()
            context.current.render_tracker:completed()
            return 'clicked'
        end)

        assert.equals('clicked', result)
        assert.equals(2, context.current.render_tracker:generation())
    end)

    it('rejects duplicate propagated IDs and recovers after tree changes',
            function()
        local first = {view_id='duplicate', subviews={}}
        local second = {view_id='duplicate', subviews={}}
        context:mount(TestWidget, {
            name='duplicate-root',
            subviews={first, second},
        })

        assert.has_error(function() context:find_view('duplicate') end,
            'DwarfSpec get is ambiguous: view_id="duplicate" mount=1 ' ..
                'matches 2 views')

        context:mutate('remove duplicate child', function()
            table.remove(context.current.root.subviews, 2)
            context.current.render_tracker:completed()
        end)

        assert.equals(first, context:find_view('duplicate'))
    end)

    it('retains selected view and mount identity for command failures',
            function()
        local retained
        local child = {view_id='submit', subviews={}}
        context:mount(TestWidget, {
            name='failure-root',
            subviews={child},
        })
        context.failure_reporter=function(mount, operation, failure)
            retained = {
                operation=operation,
                selected=mount.command_subject,
                failure=failure,
            }
            return failure
        end
        context.subject_commands.click=function()
            error('click exploded')
        end
        local selected = context:new_subject(child, 'submit')

        local ok, message = pcall(selected.click, selected)

        assert.is_false(ok)
        assert.matches('operation="click" view_id="submit" ' ..
            'subject_mount=1 current_mount=1', message, 1, true)
        assert.matches('click exploded', message, 1, true)
        assert.equals('click', retained.operation)
        assert.same({mount_id=1, view_id='submit'}, retained.selected)
        assert.matches('click exploded', retained.failure, 1, true)
        assert.is_nil(context.current.command_subject)
    end)

    it('reports render failure without advancing completion', function()
        fail_render = true

        local ok, message = pcall(context.mount, context,
            TestWidget, {name='render-failure'})

        assert.is_false(ok)
        assert.matches('render exploded for render%-failure', message)
        assert.is_nil(context.current)
        assert.equals(0, cleanup.pending_count(registry))
    end)

    it('fully unmounts and settles before constructing a replacement',
            function()
        local first_subject = context:mount(TestWidget, {name='first'})
        local Replacement = make_class(Widget, function()
            assert.equals('settle:first', events[#events])
        end)

        local second_subject = context:mount(Replacement, {name='second'})

        assert.same({
            'mount:first', 'resource:first', 'unmount:first', 'settle:first',
            'mount:second',
        }, events)
        assert.is_false(screens[1].active)
        assert.is_true(screens[2].active)
        assert.equals(2, context.current.id)
        assert.equals('second', second_subject:raw().name)
        assert.has_error(function() first_subject:raw() end,
            'DwarfSpec subject raw access rejected stale subject ' ..
            'view_id="<root>" from mount 1; current mount is 2')
        local invoked = false
        context.subject_commands.click=function()
            invoked = true
        end
        local command_ok, command_error = pcall(first_subject.click,
            first_subject)
        assert.is_false(command_ok)
        assert.matches('view_id="<root>" subject_mount=1 ' ..
            'current_mount=2', command_error, 1, true)
        assert.matches('current mount is 2', command_error, 1, true)
        assert.is_false(invoked)
    end)

    it('explicitly unmounts once and remains cleanup-idempotent', function()
        local root_subject = context:mount(TestWidget, {name='explicit'})

        context:unmount()

        assert.is_nil(context.current)
        assert.is_false(screens[1].active)
        assert.equals(0, cleanup.pending_count(registry))
        assert.same({
            'mount:explicit', 'resource:explicit',
            'unmount:explicit', 'settle:explicit',
        }, events)
        assert.has_error(function() root_subject:raw() end,
            'DwarfSpec subject raw access rejected stale subject ' ..
            'view_id="<root>" from mount 1; no component is currently mounted')
        assert.is_true(cleanup.run(registry, 'post-unmount reset'))
        assert.same(4, #events)
    end)

    it('reverses partial activation failure without a pending mount',
            function()
        fail_activation = true

        local ok, message = pcall(context.mount, context,
            TestWidget, {name='partial'})

        assert.is_false(ok)
        assert.matches('DwarfSpec mount failed while activating widget ' ..
            'component:', message, 1, true)
        assert.matches('activation exploded for partial', message, 1, true)
        assert.is_nil(context.current)
        assert.is_false(screens[1].active)
        assert.equals(0, cleanup.pending_count(registry))
        assert.same({
            'mount:partial', 'resource:partial',
            'unmount:partial', 'settle:partial',
        }, events)
    end)

    it('reverses activation when adapter result validation fails', function()
        invalid_result = true

        local ok, message = pcall(context.mount, context,
            TestWidget, {name='invalid'})

        assert.is_false(ok)
        assert.matches('component adapter mount() must return a table or nil',
            message, 1, true)
        assert.is_nil(context.current)
        assert.is_false(screens[1].active)
        assert.equals(0, cleanup.pending_count(registry))
    end)

    it('reverses activation when root subject creation fails', function()
        fail_subject = true

        local ok, message = pcall(context.mount, context,
            TestWidget, {name='subject'})

        assert.is_false(ok)
        assert.matches('DwarfSpec mount failed while creating root subject:',
            message, 1, true)
        assert.matches('subject creation exploded', message, 1, true)
        assert.is_nil(context.current)
        assert.is_false(screens[1].active)
        assert.equals(0, cleanup.pending_count(registry))
    end)

    it('leaves no mount when replacement construction fails', function()
        context:mount(TestWidget, {name='first'})
        local FailingWidget = make_class(Widget, function()
            error('replacement construction exploded')
        end)

        local ok, message = pcall(context.mount, context, FailingWidget)

        assert.is_false(ok)
        assert.matches('replacement construction exploded', message, 1, true)
        assert.is_nil(context.current)
        assert.is_false(screens[1].active)
        assert.equals(0, cleanup.pending_count(registry))
        assert.equals('settle:first', events[#events])
    end)

    it('run cleanup removes the active mount and all mount entries', function()
        context:mount(TestWidget, {name='lifecycle'})

        assert.is_true(cleanup.run(registry, 'example completion'))

        assert.is_nil(context.current)
        assert.is_false(screens[1].active)
        assert.equals(0, cleanup.pending_count(registry))
    end)

    it('reports every command clearly when there is no current mount',
            function()
        local expected = ' requires a mounted component; call ' ..
            'ds.mount(component, options) first'
        assert.has_error(function() context:root() end,
            'DwarfSpec root' .. expected)
        assert.has_error(function() context:unmount() end,
            'DwarfSpec unmount' .. expected)
        assert.has_error(function() context:require_current('get') end,
            'DwarfSpec get' .. expected)
        assert.has_error(function() context:require_current('interaction') end,
            'DwarfSpec interaction' .. expected)
    end)
end)
