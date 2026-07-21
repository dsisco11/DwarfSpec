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
                    viewport=function(_, mount, viewport)
                        local screen = mount.adapter_screen
                        screen.width = viewport.width
                        screen.height = viewport.height
                        table.insert(events, ('viewport:%d:%d'):format(
                            viewport.width, viewport.height))
                        mount.render_tracker:completed()
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
        assert.equals('k', getmetatable(context.owned_screens).__mode)
        assert.equals('k', getmetatable(mounted.selected_subjects).__mode)
        assert.equals(mounted.id, context.view_mounts[mounted.root])
        assert.same({
            current_mount_id=1,
            active_screen_count=1,
            tracked_screen_count=1,
            subject_count=1,
        }, context:cleanup_state())
    end)

    it('refreshes descendant ownership and control paths after dynamic mutations',
            function()
        local original = {view_id='original', subviews={}}
        local nested = {view_id='nested', subviews={original}}
        context:mount(TestWidget, {
            name='dynamic-root',
            subviews={nested},
        })

        assert.equals(nested, context:resolve_control_path('nested'))
        assert.equals(original,
            context:resolve_control_path('nested/original'))
        assert.equals(context.current.id, context.view_mounts[original])
        local original_subject = context:new_subject(original, 'nested/original')
        local dynamic = {view_id='dynamic', subviews={}}

        context:mutate('add dynamic child', function()
            table.insert(nested.subviews, dynamic)
            context.current.render_tracker:completed()
        end)

        assert.equals(dynamic, context:resolve_control_path('nested/dynamic'))
        assert.equals(context.current.id, context.view_mounts[dynamic])

        context:mutate('remove original child', function()
            table.remove(nested.subviews, 1)
            context.current.render_tracker:completed()
        end)

        local resolved, missing = pcall(context.resolve_control_path, context,
            'nested/original')
        assert.is_false(resolved)
        assert.matches('missing segment="original"', missing, 1, true)
        assert.is_nil(context.view_mounts[original])
        assert.has_error(function() original_subject:raw() end,
            'DwarfSpec subject raw access rejected subject ' ..
                'control_path="nested/original" mount=1 because its view is outside ' ..
                'the current mount')

        context:mutate('reparent dynamic child', function()
            table.remove(nested.subviews, 1)
            table.insert(context.current.root.subviews, dynamic)
            context.current.render_tracker:completed()
        end)

        assert.equals(dynamic, context:resolve_control_path('dynamic'))
        assert.has_error(function()
            context:resolve_control_path('nested/dynamic')
        end, 'DwarfSpec get failed: control_path="nested/dynamic" mount=1 ' ..
            'missing segment="dynamic" after="nested"; available children=<none>')
    end)

    it('resolves only explicit direct-child control paths', function()
        local editor = {view_id='editor', subviews={}}
        local panel = {view_id='panel', subviews={editor}}
        context:mount(TestWidget, {name='strict-paths', subviews={panel}})

        assert.equals(panel, context:resolve_control_path('panel'))
        assert.equals(editor, context:resolve_control_path('panel/editor'))
        assert.has_error(function()
            context:resolve_control_path('editor')
        end, 'DwarfSpec get failed: control_path="editor" mount=1 missing ' ..
            'segment="editor" after="<root>"; available children=panel')
        assert.has_error(function()
            context:resolve_control_path('panel/missing')
        end, 'DwarfSpec get failed: control_path="panel/missing" mount=1 ' ..
            'missing segment="missing" after="panel"; available children=editor')
    end)

    it('does not skip anonymous or named hierarchy boundaries', function()
        local anonymous_child = {view_id='hidden', subviews={}}
        local anonymous = {subviews={anonymous_child}}
        local nested = {view_id='nested', subviews={anonymous}}
        context:mount(TestWidget, {name='boundaries', subviews={nested}})

        assert.has_error(function()
            context:resolve_control_path('hidden')
        end, 'DwarfSpec get failed: control_path="hidden" mount=1 missing ' ..
            'segment="hidden" after="<root>"; available children=nested')
        assert.has_error(function()
            context:resolve_control_path('nested/hidden')
        end, 'DwarfSpec get failed: control_path="nested/hidden" mount=1 ' ..
            'missing segment="hidden" after="nested"; available children=<none>')
    end)

    it('keeps same leaf IDs distinct beneath different parents', function()
        local left_name = {view_id='name', subviews={}}
        local right_name = {view_id='name', subviews={}}
        local left = {view_id='left', subviews={left_name}}
        local right = {view_id='right', subviews={right_name}}
        context:mount(TestWidget, {name='separate-leaves', subviews={left, right}})

        assert.equals(left_name, context:resolve_control_path('left/name'))
        assert.equals(right_name, context:resolve_control_path('right/name'))
    end)

    it('rejects malformed paths and root-ID selection', function()
        context:mount(TestWidget, {
            name='root-id',
            view_id='mounted-root',
            subviews={},
        })

        assert.has_error(function() context:resolve_control_path('') end,
            'control path must be a nonempty string')
        assert.has_error(function() context:resolve_control_path('/child') end,
            'control path cannot start or end with "/"')
        assert.has_error(function() context:resolve_control_path('child/') end,
            'control path cannot start or end with "/"')
        assert.has_error(function() context:resolve_control_path('child/../name') end,
            'control path contains reserved segment ".."')
        assert.has_error(function()
            context:resolve_control_path('mounted-root')
        end, 'DwarfSpec get failed: control_path="mounted-root" mount=1 ' ..
            'missing segment="mounted-root" after="<root>"; ' ..
            'available children=<none>')
    end)

    it('rejects reserved direct child IDs while mounting', function()
        local slash_ok, slash_error = pcall(context.mount, context,
            TestWidget, {
                name='slash-child',
                subviews={{view_id='invalid/path', subviews={}}},
            })
        assert.is_false(slash_ok)
        assert.matches('DwarfSpec invalid component tree: parent ' ..
            'control_path="<root>" has child view_id="invalid/path" ' ..
            'containing "/"', slash_error, 1, true)
        local dot_ok, dot_error = pcall(context.mount, context, TestWidget, {
            name='dot-child',
            subviews={{view_id='.', subviews={}}},
        })
        assert.is_false(dot_ok)
        assert.matches('DwarfSpec invalid component tree: parent ' ..
            'control_path="<root>" has reserved child view_id="."',
            dot_error, 1, true)
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

    it('owns default and runtime viewport state for the current mount',
            function()
        local requested = {width=40, height=20}
        context:mount(TestWidget, {name='viewport', viewport=requested})
        local mount = context.current
        requested.width = 1

        assert.same({width=40, height=20}, mount.options.viewport)
        context:viewport(60, 30)
        assert.same({width=60, height=30}, mount.options.viewport)
        assert.equals(60, screens[1].width)
        assert.equals(30, screens[1].height)
        assert.equals('viewport:60:30', events[#events])
        assert.equals(2, mount.render_tracker:generation())

        context:viewport(61, 31)
        assert.same({width=61, height=31}, mount.options.viewport)
        assert.equals(61, screens[1].width)
        assert.equals(31, screens[1].height)
        assert.equals('viewport:61:31', events[#events])
        assert.equals(3, mount.render_tracker:generation())

        assert.has_error(function() context:viewport(0, 30) end,
            'mount option viewport.width must be a positive integer')
        assert.has_error(function() context:viewport(60, 30.5) end,
            'mount option viewport.height must be a positive integer')
    end)

    it('starts each mount with an independent default viewport', function()
        context:mount(TestWidget, {name='first'})
        context:viewport(60, 30)
        context:unmount()
        context:mount(TestWidget, {name='second'})

        assert.same({width=128, height=64}, context.current.options.viewport)
    end)

    it('rejects duplicate direct child IDs while mounting',
            function()
        local first = {view_id='duplicate', subviews={}}
        local second = {view_id='duplicate', subviews={}}
        local mounted, failure = pcall(context.mount, context, TestWidget, {
            name='duplicate-root',
            subviews={first, second},
        })
        assert.is_false(mounted)
        assert.matches('DwarfSpec invalid component tree: parent ' ..
            'control_path="<root>" has multiple direct children with ' ..
            'view_id="duplicate"', failure, 1, true)
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
        assert.matches('operation="click" control_path="submit" ' ..
            'subject_mount=1 current_mount=1', message, 1, true)
        assert.matches('click exploded', message, 1, true)
        assert.equals('click', retained.operation)
        assert.same({mount_id=1, control_path='submit'}, retained.selected)
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

    it('rejects a second mount until the current mount is unmounted',
            function()
        local first_subject = context:mount(TestWidget, {name='first'})
        local constructed = false
        local NextWidget = make_class(Widget, function()
            constructed = true
            assert.equals('settle:first', events[#events])
        end)

        assert.has_error(function()
            context:mount(NextWidget, {name='second'})
        end, 'DwarfSpec mount rejected because mount 1 is still current; ' ..
            'call ds.unmount() before mounting another component')

        assert.same({
            'mount:first',
        }, events)
        assert.is_false(constructed)
        assert.is_true(screens[1].active)
        assert.equals(1, context.current.id)
        assert.equals('first', first_subject:raw().name)

        context:unmount()
        local second_subject = context:mount(NextWidget, {name='second'})

        assert.same({
            'mount:first', 'resource:first', 'unmount:first', 'settle:first',
            'mount:second',
        }, events)
        assert.is_true(constructed)
        assert.is_false(screens[1].active)
        assert.is_true(screens[2].active)
        assert.equals(2, context.current.id)
        assert.equals('second', second_subject:raw().name)
        assert.has_error(function() first_subject:raw() end,
            'DwarfSpec subject raw access rejected stale subject ' ..
            'control_path="<root>" from mount 1; current mount is 2')
        local invoked = false
        context.subject_commands.click=function()
            invoked = true
        end
        local command_ok, command_error = pcall(first_subject.click,
            first_subject)
        assert.is_false(command_ok)
        assert.matches('control_path="<root>" subject_mount=1 ' ..
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
            'control_path="<root>" from mount 1; no component is currently mounted')
        assert.same({
            current_mount_id=nil,
            active_screen_count=0,
            tracked_screen_count=1,
            subject_count=0,
        }, context:cleanup_state())
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

    it('leaves no mount when construction fails after explicit unmount',
            function()
        context:mount(TestWidget, {name='first'})
        context:unmount()
        local FailingWidget = make_class(Widget, function()
            error('component construction exploded')
        end)
        local retained
        context.failure_reporter=function(mount, operation, failure)
            retained = {
                mount_id=mount.id,
                category=mount.category,
                operation=operation,
                failure=failure,
            }
            return ('reported %s failure for mount %d: %s')
                :format(operation, mount.id, failure)
        end

        local ok, message = pcall(context.mount, context, FailingWidget)

        assert.is_false(ok)
        assert.matches('reported mount failure for mount 2:',
            message, 1, true)
        assert.matches('component construction exploded', message, 1, true)
        assert.equals(2, retained.mount_id)
        assert.equals('widget', retained.category)
        assert.equals('mount', retained.operation)
        assert.matches('DwarfSpec mount failed while constructing widget ' ..
            'component:', retained.failure, 1, true)
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
        assert.has_error(function() context:viewport(80, 25) end,
            'DwarfSpec viewport' .. expected)
    end)
end)
