-- Unit contracts for run-owned component mount orchestration.

local cleanup = assert(loadfile(
    'src/dwarfspec/host/execution/cleanup.lua'))()
local component = assert(loadfile('src/dwarfspec/driver/mount/component.lua'))()
local mount_context = assert(loadfile(
    'src/dwarfspec/driver/mount/mount_context.lua'))()
local render_tracker = assert(loadfile(
    'src/dwarfspec/driver/render/render_tracker.lua'))()
local subject = assert(loadfile('src/dwarfspec/driver/subjects/subject.lua'))()
local lua_view_adapter = assert(loadfile(
    'src/dwarfspec/driver/subjects/lua_view_adapter.lua'))()
local interaction_target = require('dwarfspec.driver.subjects.interaction_target')
local native_widget_adapter = require('dwarfspec.driver.subjects.native_widget_adapter')

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
    local interaction_targets
    local context
    local fail_activation
    local invalid_result
    local fail_subject
    local fail_render
    local fail_adapter_cleanup
    local native_observer_installs
    local native_observer_restores
    local native_observer_install_failure
    local native_observer_restore_failure
    local cleanup_push_count
    local cleanup_push_failure_at
    local expected_pending
    local native_cleanup_events

    before_each(function()
        Widget = make_class()
        OverlayWidget = make_class(Widget)
        ZScreen = make_class()
        TestWidget = make_class(Widget)
        registry = cleanup.new({run_id='mount-context-test'})
        events = {}
        screens = {}
        interaction_targets = {}
        fail_activation = false
        invalid_result = false
        fail_subject = false
        fail_render = false
        fail_adapter_cleanup = false
        native_observer_installs = 0
        native_observer_restores = 0
        native_observer_install_failure = nil
        native_observer_restore_failure = nil
        cleanup_push_count = 0
        cleanup_push_failure_at = nil
        expected_pending = 1
        native_cleanup_events = {}
        local boundary = component.new({
            Widget=Widget,
            OverlayWidget=OverlayWidget,
            ZScreen=ZScreen,
        })
        local cleanup_services = {
            mark=cleanup.mark,
            run_from=cleanup.run_from,
            push=function(...)
                cleanup_push_count = cleanup_push_count + 1
                if cleanup_push_count == cleanup_push_failure_at then
                    error('injected cleanup registration failure', 0)
                end
                return cleanup.push(...)
            end,
        }
        context = mount_context.new({
            run=registry.run,
            boundary=boundary,
            cleanup_module=cleanup_services,
            cleanup_registry=registry,
            render_tracker_factory=function()
                return render_tracker.new({
                    wait_until=function(_, _, query)
                        return assert(query(), 'render did not complete')
                    end,
                }, {})
            end,
            native_render_observer_factory=function()
                native_observer_installs =
                    native_observer_installs + 1
                if native_observer_install_failure then
                    error(native_observer_install_failure, 0)
                end
                return function()
                    table.insert(native_cleanup_events, 'observer')
                    native_observer_restores =
                        native_observer_restores + 1
                    if native_observer_restore_failure then
                        error(native_observer_restore_failure, 0)
                    end
                    return true
                end
            end,
            subject_module={
                new=function(...)
                    if fail_subject then error('subject creation exploded') end
                    return subject.new(...)
                end,
                release=function(value)
                    table.insert(native_cleanup_events, 'subject')
                    return subject.release(value)
                end,
            },
            adapter_factory=function(category)
                assert.equals('widget', category)
                return {
                    mount=function(_, mount, prepared, register_cleanup)
                        assert.equals(expected_pending, cleanup.pending_count(registry))
                        local screen = {active=true, name=prepared.component.name}
                        table.insert(screens, screen)
                        table.insert(events, 'mount:' .. screen.name)
                        register_cleanup('adapter resource ' .. screen.name,
                            function()
                                table.insert(events, 'resource:' .. screen.name)
                                if fail_adapter_cleanup then
                                    error('adapter cleanup exploded for ' ..
                                        screen.name)
                                end
                            end)
                        mount.adapter_screen = screen
                        if fail_activation then
                            error('activation exploded for ' .. screen.name)
                        end
                        if invalid_result then return 'invalid adapter result' end
                        local interaction_target = {
                            cleaned=false,
                            assert_current=function(self)
                                assert.is_false(self.cleaned)
                                assert.is_true(screen.active)
                                return screen
                            end,
                            native_screen=function(self)
                                return self:assert_current()
                            end,
                            invalidate=function(self)
                                return self:assert_current()
                            end,
                            cleanup=function(self)
                                if self.cleaned then return false end
                                self.cleaned = true
                                return true
                            end,
                        }
                        table.insert(interaction_targets,
                            interaction_target)
                        if fail_render then
                            mount.render_tracker:failed(
                                'render exploded for ' .. screen.name)
                        else
                            mount.render_tracker:completed()
                        end
                        return {
                            root=prepared.component,
                            host_screen=screen,
                            interaction_target=interaction_target,
                            subject_source=lua_view_adapter.new_source(
                                prepared.component),
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

    it('mounts a module descriptor through one fresh TestBed and closes it after the component', function()
        local close_count = 0
        expected_pending = 2
        context.testbed_host = {}
        context.testbed_adapter = {new=function(config)
            assert.is_nil(config)
            return {
                require=function(_, name)
                    assert.equals('fixture', name)
                    return TestWidget
                end,
                reqscript=function() error('unexpected script load') end,
                close=function()
                    close_count = close_count + 1
                    table.insert(events, 'bed-close')
                end,
            }
        end}

        local mounted = context:mount_descriptor({kind='module', name='fixture'},
            {name='descriptor'})
        assert.equals(1, mounted.mount_id)
        context:unmount()
        assert.equals(1, close_count)
        assert.equals('unmount:descriptor', events[#events - 2])
        assert.equals('bed-close', events[#events])
        assert.equals(0, cleanup.pending_count(registry))
    end)

    it('uses reqscript and forwards explicit TestBed configuration separately', function()
        local received_config
        expected_pending = 2
        context.testbed_host = {}
        context.testbed_adapter = {new=function(config)
            received_config = config
            return {require=function() error('unexpected module load') end,
                reqscript=function(_, name)
                    assert.equals('fixture', name)
                    return {Named=TestWidget}
                end,
                close=function() end}
        end}
        local subject = context:mount_descriptor(
            {kind='script', name='fixture', export='Named'},
            {name='component'}, {component_imports=false})
        assert.equals('component', subject:raw().name)
        assert.same({component_imports=false}, received_config)
    end)

    it('forwards omitted and explicit configuration for both descriptor kinds', function()
        local received = {}
        expected_pending = 2
        context.testbed_host = {}
        context.testbed_adapter = {new=function(config)
            table.insert(received, {config=config})
            return {
                require=function() return TestWidget end,
                reqscript=function() return TestWidget end,
                close=function() end,
            }
        end}

        context:mount_descriptor({kind='script', name='omitted'}, {name='script'})
        context:unmount()
        context:mount_descriptor({kind='module', name='explicit'},
            {name='module'}, {component_imports=false})
        context:unmount()

        assert.is_nil(received[1].config)
        assert.same({component_imports=false}, received[2].config)
    end)

    it('passes empty descriptor names and exports to the underlying loader', function()
        local requested_name
        expected_pending = 2
        context.testbed_host = {}
        context.testbed_adapter = {new=function()
            return {require=function(_, name)
                requested_name = name
                return {['']=TestWidget}
            end, reqscript=function() error('unexpected script load') end,
                close=function() end}
        end}
        context:mount_descriptor({kind='module', name='', export=''},
            {name='empty'})
        assert.equals('', requested_name)
    end)

    it('keeps overlapping component options and TestBed configuration separate', function()
        local received_config
        expected_pending = 2
        context.testbed_host = {}
        context.testbed_adapter = {new=function(config)
            received_config = config
            return {require=function() return TestWidget end,
                reqscript=function() error('unexpected script load') end,
                close=function() end}
        end}
        local subject = context:mount_descriptor({kind='module', name='fixture'},
            {globals='component value', name='separate'},
            {globals={custom='TestBed value'}})
        assert.equals('component value', subject:raw().globals)
        assert.equals('TestBed value', received_config.globals.custom)
    end)

    it('creates a fresh TestBed for each consecutive descriptor mount', function()
        local beds = {}
        expected_pending = 2
        context.testbed_host = {}
        context.testbed_adapter = {new=function()
            local bed = {closed=false, require=function() return TestWidget end,
                reqscript=function() error('unexpected script load') end,
                close=function(self) self.closed = true end}
            table.insert(beds, bed)
            return bed
        end}
        context:mount_descriptor({kind='module', name='first'}, {name='first'})
        context:unmount()
        context:mount_descriptor({kind='module', name='second'}, {name='second'})
        context:unmount()
        assert.equals(2, #beds)
        assert.is_not_equal(beds[1], beds[2])
        assert.is_true(beds[1].closed)
        assert.is_true(beds[2].closed)
    end)

    it('rejects malformed descriptors before allocating a TestBed', function()
        local allocations = 0
        context.testbed_host = {}
        context.testbed_adapter = {new=function() allocations = allocations + 1 end}
        for _, descriptor in ipairs({
            {}, {kind='other', name='fixture'}, {kind='module', name=1},
            {kind='module', name='fixture', export=1},
            {kind='module', name='fixture', extra=true},
        }) do
            assert.has_error(function() context:mount_descriptor(descriptor) end)
        end
        assert.equals(0, allocations)
        assert.equals(0, cleanup.pending_count(registry))
    end)

    it('rejects instantiated TestBeds and invalid descriptor exports before mounting', function()
        local TestBed = require('dwarfspec.testbed')
        local bed = TestBed.new()
        context.testbed_host = {}
        context.testbed_adapter = {new=function()
            return {require=function() return {missing=nil, invalid={}} end,
                reqscript=function() error('unexpected script load') end,
                close=function() end}
        end}
        assert.has_error(function()
            context:mount_descriptor({kind='module', name='fixture'}, nil, bed)
        end)
        bed:close()
        assert.has_error(function()
            context:mount_descriptor({kind='module', name='fixture'}, nil, bed)
        end)
        assert.has_error(function()
            context:mount_descriptor({kind='module', name='fixture', export='missing'})
        end)
        assert.has_error(function()
            context:mount_descriptor({kind='module', name='fixture', export='invalid'})
        end)
    end)

    it('closes a descriptor TestBed after loader and export failures', function()
        local close_count = 0
        context.testbed_host = {}
        context.testbed_adapter = {new=function()
            return {require=function() error('loader failed') end,
                reqscript=function() error('loader failed') end,
                close=function() close_count = close_count + 1 end}
        end}
        local ok, failure = pcall(function()
            context:mount_descriptor({kind='module', name='fixture'})
        end)
        assert.is_false(ok)
        assert.matches('loader failed', failure, 1, true)
        assert.equals(1, close_count)
        assert.equals(0, cleanup.pending_count(registry))
    end)

    it('closes an unregistered TestBed when cleanup registration fails', function()
        local close_count = 0
        cleanup_push_failure_at = 1
        context.testbed_host = {}
        context.testbed_adapter = {new=function()
            return {close=function() close_count = close_count + 1 end}
        end}
        assert.has_error(function()
            context:mount_descriptor({kind='module', name='fixture'})
        end)
        assert.equals(1, close_count)
        assert.equals(0, cleanup.pending_count(registry))
    end)

    it('leaves no cleanup registration when TestBed construction fails', function()
        context.testbed_host = {}
        context.testbed_adapter = {new=function() error('adapter setup failed') end}
        local ok, failure = pcall(function()
            context:mount_descriptor({kind='module', name='fixture'})
        end)
        assert.is_false(ok)
        assert.matches('adapter setup failed', failure, 1, true)
        assert.equals(0, cleanup.pending_count(registry))
    end)

    it('does not allocate TestBeds for ordinary class mount success or failure', function()
        local allocations = 0
        context.testbed_host = {}
        context.testbed_adapter = {new=function()
            allocations = allocations + 1
            error('ordinary class mounts must not construct TestBeds')
        end}

        context:mount(TestWidget, {name='class-success'})
        context:unmount()
        fail_activation = true
        assert.has_error(function()
            context:mount(TestWidget, {name='class-failure'})
        end)

        assert.equals(0, allocations)
        assert.equals(0, cleanup.pending_count(registry))
    end)

    it('closes descriptor TestBeds for constructor, mount, assertion, and cleanup failures', function()
        local close_count = 0
        local ConstructorFailure = make_class(Widget, function()
            error('descriptor constructor exploded')
        end)
        expected_pending = 2
        context.testbed_host = {}
        context.testbed_adapter = {new=function()
            return {
                require=function(_, name)
                    if name == 'constructor' then return ConstructorFailure end
                    return TestWidget
                end,
                reqscript=function() error('unexpected script load') end,
                close=function()
                    close_count = close_count + 1
                    table.insert(events, 'bed-close')
                end,
            }
        end}

        assert.has_error(function()
            context:mount_descriptor({kind='module', name='constructor'})
        end)
        fail_activation = true
        assert.has_error(function()
            context:mount_descriptor({kind='module', name='mount'}, {name='mount'})
        end)
        fail_activation = false
        invalid_result = true
        assert.has_error(function()
            context:mount_descriptor({kind='module', name='assertion'}, {name='assertion'})
        end)
        invalid_result = false
        fail_adapter_cleanup = true
        context:mount_descriptor({kind='module', name='cleanup'}, {name='cleanup'})
        assert.has_error(function() context:unmount() end)

        assert.equals(4, close_count)
        assert.equals(0, cleanup.pending_count(registry))
        assert.equals('bed-close', events[#events])
    end)

    it('closes exactly once after component teardown on descriptor success and failures', function()
        local close_count = 0
        expected_pending = 2
        context.testbed_host = {}
        context.testbed_adapter = {new=function()
            return {
                require=function() return TestWidget end,
                reqscript=function() error('unexpected script load') end,
                close=function()
                    close_count = close_count + 1
                    table.insert(events, 'bed-close')
                end,
            }
        end}
        local function assert_component_before_bed(name, configure,
                cleanup_fails)
            configure()
            local ok = pcall(function()
                context:mount_descriptor({kind='module', name=name}, {name=name})
            end)
            if ok then
                local unmount_ok = pcall(function() context:unmount() end)
                assert.equals(not cleanup_fails, unmount_ok)
            end
            assert.equals('bed-close', events[#events])
            local unmount_index
            for index, event in ipairs(events) do
                if event == 'unmount:' .. name then unmount_index = index end
            end
            assert.is_not_nil(unmount_index)
            assert.is_true(unmount_index < #events)
        end

        assert_component_before_bed('normal', function() end)
        assert_component_before_bed('mount-failure', function()
            fail_activation = true
        end)
        fail_activation = false
        assert_component_before_bed('assertion-failure', function()
            invalid_result = true
        end)
        invalid_result = false
        fail_adapter_cleanup = true
        assert_component_before_bed('cleanup-failure', function() end, true)

        assert.equals(4, close_count)
        assert.equals(0, cleanup.pending_count(registry))
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
        assert.equals(interaction_targets[1],
            mounted.interaction_target)
        assert.equals(mounted.root,
            mounted.subject_source.adapter:root())
        assert.is_nil(context.owned_screens[mounted.interaction_target])
        assert.is_nil(context.owned_screens[mounted.subject_source])
        assert.is_true(mounted.alive)
        assert.is_nil(mounted.active)
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
            owned_screen_count=1,
            borrowed_native_screen_count=0,
            native_attachment_count=0,
            native_screen_dismissal_count=0,
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
        local stale_ok, stale_failure =
            pcall(original_subject.raw, original_subject)
        assert.is_false(stale_ok)
        assert.matches('DwarfSpec subject raw access rejected subject ' ..
                'control_path="nested/original" mount=1 because its view is outside ' ..
                'the current mount', stale_failure, 1, true)
        assert.matches('mount_kind="widget" source="component" ' ..
            'captured_identity=table#%d+ current_identity=<nil>',
            stale_failure)

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

    it('rejects a retained subject when its path is rebound',
            function()
        local original = {view_id='status', subviews={}}
        context:mount(TestWidget, {
            name='replacement-root',
            subviews={original},
        })
        local selected = context:new_subject(original, 'status')
        local replacement = {view_id='status', subviews={}}

        context:mutate('replace child', function()
            context.current.root.subviews[1] = replacement
            context.current.render_tracker:completed()
        end)

        assert.equals(replacement,
            context:resolve_control_path('status'))
        local stale_ok, stale_failure = pcall(selected.raw, selected)
        assert.is_false(stale_ok)
        assert.matches('DwarfSpec subject raw access rejected subject ' ..
            'control_path="status" mount=1 because its view is outside ' ..
            'the current mount', stale_failure, 1, true)
        assert.matches('mount_kind="widget" source="component" ' ..
            'captured_identity=table#%d+ current_identity=table#%d+',
            stale_failure)
        assert.equals(replacement,
            context:new_subject(replacement, 'status'):raw())
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

    it('can run a mutating operation without waiting for a render', function()
        context:mount(TestWidget, {name='mutated-without-wait'})
        local generation = context.current.render_tracker:generation()

        local result = context:mutate('redraw', function()
            return 'redrawn'
        end, {wait_for_render=false})

        assert.equals('redrawn', result)
        assert.equals(generation,
            context.current.render_tracker:generation())
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
            'call ds.unmount() before creating another mount')

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
        assert.is_true(interaction_targets[1].cleaned)
        assert.is_true(screens[2].active)
        assert.equals(2, context.current.id)
        assert.equals('second', second_subject:raw().name)
        assert.has_error(function() first_subject:raw() end,
            'stage=retained_subject_reacquisition ' ..
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
        local mounted = context.current
        local mounted_target = mounted.interaction_target
        local mounted_subject_adapter =
            mounted.subject_source.adapter

        context:unmount()

        assert.is_nil(context.current)
        assert.is_false(mounted.alive)
        assert.is_true(mounted_target.cleaned)
        assert.has_error(function() mounted_subject_adapter:root() end,
            'Lua view subject source is no longer available')
        assert.is_nil(root_subject._descriptor)
        assert.is_nil(mounted.active)
        assert.is_false(screens[1].active)
        assert.equals(0, cleanup.pending_count(registry))
        assert.same({
            'mount:explicit', 'resource:explicit',
            'unmount:explicit', 'settle:explicit',
        }, events)
        assert.has_error(function() root_subject:raw() end,
            'stage=retained_subject_reacquisition ' ..
            'DwarfSpec subject raw access rejected stale subject ' ..
            'control_path="<root>" from mount 1; no current mount exists')
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

    it('tracks a borrowed native attachment without owning its screen',
            function()
        local root = {kind='native-root'}
        local pinned = {
            widgets=root,
            dismissals=0,
        }
        local current = pinned
        local target = interaction_target.new_borrowed_native(pinned, {
            get_current_viewscreen=function() return current end,
            invalidate_screen=function()
                context.current.render_tracker:completed()
            end,
        })
        local original_target_cleanup = target.cleanup
        target.cleanup = function(self)
            table.insert(native_cleanup_events, 'attachment')
            return original_target_cleanup(self)
        end
        local source = native_widget_adapter.new_source(root, target, {
            get_widget=function() return nil end,
            get_children=function() return {} end,
            is_container=function() return true end,
        })
        local original_source_cleanup = source.adapter.cleanup
        source.adapter.cleanup = function(self)
            table.insert(native_cleanup_events, 'source')
            return original_source_cleanup(self)
        end

        local mounted = context:mount_native_screen(function()
            return {
                root=root,
                pinned_screen=pinned,
                interaction_target=target,
                subject_source=source,
            }
        end)

        assert.equals(root, mounted:raw())
        assert.equals(root, context.current.root)
        assert.equals(pinned, context.current.pinned_screen)
        assert.is_nil(context.current.host_screen)
        assert.equals(1, native_observer_installs)
        assert.equals(0, native_observer_restores)
        assert.equals(1, context.current.render_tracker:generation())
        assert.same({
            current_mount_id=1,
            active_screen_count=0,
            tracked_screen_count=0,
            owned_screen_count=0,
            borrowed_native_screen_count=1,
            native_attachment_count=1,
            native_screen_dismissal_count=0,
            subject_count=1,
        }, context:cleanup_state())

        context:unmount()

        assert.is_true(target._cleaned)
        assert.equals(1, native_observer_restores)
        assert.same({
            'observer',
            'subject',
            'source',
            'attachment',
        }, native_cleanup_events)
        assert.equals(0, pinned.dismissals)
        assert.equals(0, cleanup.pending_count(registry))
    end)

    it('retains, reuses, and rejects located native sources by identity',
            function()
        local first_child = {
            id='stable-child',
            name='Status',
            children={},
        }
        local first_root = {
            id='stable-root',
            children={first_child},
            dismissals=0,
            mutations=0,
        }
        local located_root = first_root
        local pinned = {widgets={}, dismissals=0}
        local current_screen = pinned
        local target = interaction_target.new_borrowed_native(pinned, {
            get_current_viewscreen=function() return current_screen end,
            invalidate_screen=function()
                context.current.render_tracker:completed()
            end,
        })

        ---Creates a source for the current structural root fixture.
        ---@return dwarfspec.SubjectSource
        local function located_source()
            return native_widget_adapter.new_source(
                located_root, target, {
                    root_locator=function() return located_root end,
                    structural_path={'info', 'creatures'},
                    get_widget=function(parent, segment)
                        for _, child in ipairs(parent.children) do
                            if child.name == segment then return child end
                        end
                        return nil
                    end,
                    get_children=function(parent)
                        return parent.children
                    end,
                    is_container=function(raw)
                        return raw.children ~= nil
                    end,
                    identity_of=function(raw) return raw.id end,
                    name_of=function(raw) return raw.name end,
                    type_of=function() return 'df.widget_container' end,
                })
        end

        local source = located_source()
        context:mount_native_screen(function()
            return {
                root=first_root,
                pinned_screen=pinned,
                interaction_target=target,
                subject_source=source,
            }
        end)
        local initial = source.adapter:resolve({'Status'})
        local retained = context:new_subject(
            initial, '{"Status"}', {'Status'}, source)

        local duplicate = located_source()
        local registered = context:register_subject_source(duplicate)
        local registered_count = 0
        for _ in pairs(context.current.subject_sources) do
            registered_count = registered_count + 1
        end
        assert.equals(source, registered)
        assert.equals(1, registered_count)
        assert.is_true(duplicate.adapter._cleaned)

        local second_child = {
            id='stable-child',
            name='Status',
            children={},
        }
        local second_root = {
            id='stable-root',
            children={second_child},
            dismissals=0,
            mutations=0,
        }
        located_root = second_root
        assert.equals(second_child, retained:raw())

        local replaced_child = {
            id='replacement-child',
            name='Status',
            children={},
        }
        located_root = {
            id='stable-root',
            children={replaced_child},
        }
        local child_ok, child_failure = pcall(retained.raw, retained)
        assert.is_false(child_ok)
        assert.matches(
            'because the widget was replaced', child_failure, 1, true)

        located_root = nil
        local removed_ok, removed_failure =
            pcall(retained.raw, retained)
        assert.is_false(removed_ok)
        assert.matches(
            'structural root no longer resolves',
            removed_failure, 1, true)

        located_root = {
            id='replacement-root',
            children={second_child},
        }
        local root_ok, root_failure = pcall(retained.raw, retained)
        assert.is_false(root_ok)
        assert.matches(
            'structural root was replaced', root_failure, 1, true)

        located_root = second_root
        current_screen = {}
        assert.equals(second_child, retained:raw())

        context:unmount()
        local unmounted_ok, unmounted_failure =
            pcall(retained.raw, retained)
        assert.is_false(unmounted_ok)
        assert.matches(
            'no current mount exists', unmounted_failure, 1, true)
        assert.is_nil(source.adapter._root)
        assert.is_nil(source.adapter._root_locator)
        assert.is_nil(source.adapter._root_identity)
        assert.is_nil(source.adapter._structural_path)
        assert.equals(0, first_root.dismissals)
        assert.equals(0, first_root.mutations)
        assert.equals(0, second_root.dismissals)
        assert.equals(0, second_root.mutations)
        assert.equals(0, pinned.dismissals)
    end)

    it('releases a located source during exceptional native cleanup',
            function()
        local root = {
            id='stable-root',
            children={},
            dismissals=0,
            mutations=0,
        }
        local pinned = {widgets=root, dismissals=0}
        local target = interaction_target.new_borrowed_native(pinned, {
            get_current_viewscreen=function() return pinned end,
            invalidate_screen=function()
                context.current.render_tracker:completed()
            end,
        })
        local source = native_widget_adapter.new_source(root, target, {
            root_locator=function() return root end,
            structural_path={'info', 'creatures'},
            get_widget=function() return nil end,
            get_children=function() return {} end,
            is_container=function() return true end,
            identity_of=function(raw) return raw.id end,
        })
        native_observer_restore_failure =
            'injected observation restoration conflict'
        context:mount_native_screen(function()
            return {
                root=root,
                pinned_screen=pinned,
                interaction_target=target,
                subject_source=source,
            }
        end)

        local ok, failure = pcall(context.unmount, context)

        assert.is_false(ok)
        assert.matches(
            'injected observation restoration conflict',
            failure, 1, true)
        assert.is_true(source.adapter._cleaned)
        assert.is_nil(source.adapter._root_locator)
        assert.is_nil(source.adapter._root_identity)
        assert.is_nil(source.adapter._structural_path)
        assert.is_true(target._cleaned)
        assert.equals(0, root.dismissals)
        assert.equals(0, root.mutations)
        assert.equals(0, pinned.dismissals)
        assert.is_nil(context.current)
    end)

    it('restores observation and attachment state after capability timeout',
            function()
        local root = {kind='native-root'}
        local pinned = {widgets=root}
        local target_cleanups = 0
        local source_cleanups = 0
        local target = interaction_target.new_borrowed_native(pinned, {
            get_current_viewscreen=function() return pinned end,
            invalidate_screen=function() end,
        })
        local original_target_cleanup = target.cleanup
        target.cleanup = function(self)
            target_cleanups = target_cleanups + 1
            return original_target_cleanup(self)
        end
        local source = native_widget_adapter.new_source(root, target, {
            get_widget=function() return nil end,
            get_children=function() return {} end,
            is_container=function() return true end,
        })
        local original_source_cleanup = source.adapter.cleanup
        source.adapter.cleanup = function(self)
            source_cleanups = source_cleanups + 1
            if original_source_cleanup then
                return original_source_cleanup(self)
            end
        end

        local ok, failure =
            pcall(context.mount_native_screen, context, function()
            return {
                root=root,
                pinned_screen=pinned,
                interaction_target=target,
                subject_source=source,
            }
        end)

        assert.is_false(ok)
        assert.matches(
            'DwarfSpec native-screen mount render capability check failed:',
            failure, 1, true)
        assert.matches('render did not complete', failure, 1, true)
        assert.equals(1, native_observer_installs)
        assert.equals(1, native_observer_restores)
        assert.equals(1, target_cleanups)
        assert.equals(1, source_cleanups)
        assert.is_nil(context.current)
        assert.equals(0, cleanup.pending_count(registry))
    end)

    it('cleans attachment resources when native observation cannot install',
            function()
        local root = {kind='native-root'}
        local pinned = {widgets=root}
        local target_cleanups = 0
        local target = interaction_target.new_borrowed_native(pinned, {
            get_current_viewscreen=function() return pinned end,
            invalidate_screen=function() end,
        })
        local original_cleanup = target.cleanup
        target.cleanup = function(self)
            target_cleanups = target_cleanups + 1
            return original_cleanup(self)
        end
        native_observer_install_failure =
            'overlay render dispatch unavailable'

        local ok, failure =
            pcall(context.mount_native_screen, context, function()
            return {
                root=root,
                pinned_screen=pinned,
                interaction_target=target,
                subject_source=native_widget_adapter.new_source(
                    root, target, {
                        get_widget=function() return nil end,
                        get_children=function() return {} end,
                        is_container=function() return true end,
                    }),
            }
        end)

        assert.is_false(ok)
        assert.matches('overlay render dispatch unavailable',
            failure, 1, true)
        assert.equals(1, native_observer_installs)
        assert.equals(0, native_observer_restores)
        assert.equals(1, target_cleanups)
        assert.is_nil(context.current)
        assert.equals(0, cleanup.pending_count(registry))
    end)

    it('continues detaching after observer restoration reports a conflict',
            function()
        local root = {kind='native-root'}
        local pinned = {widgets=root}
        local target = interaction_target.new_borrowed_native(pinned, {
            get_current_viewscreen=function() return pinned end,
            invalidate_screen=function()
                context.current.render_tracker:completed()
            end,
        })
        native_observer_restore_failure =
            'native render dispatcher changed before restoration'
        context:mount_native_screen(function()
            return {
                root=root,
                pinned_screen=pinned,
                interaction_target=target,
                subject_source=native_widget_adapter.new_source(
                    root, target, {
                        get_widget=function() return nil end,
                        get_children=function() return {} end,
                        is_container=function() return true end,
                    }),
            }
        end)

        local ok, failure = pcall(context.unmount, context)

        assert.is_false(ok)
        assert.matches(
            'native render dispatcher changed before restoration',
            failure, 1, true)
        assert.equals(1, native_observer_restores)
        assert.is_true(target._cleaned)
        assert.is_nil(context.current)
        assert.equals(0, cleanup.pending_count(registry))
    end)

    it('cleans partial native mount state after result validation fails',
            function()
        local target_cleanups = 0
        local source_cleanups = 0
        local target = {
            assert_current=function() return {} end,
            native_screen=function() return {} end,
            invalidate=function() end,
            cleanup=function()
                target_cleanups = target_cleanups + 1
            end,
        }
        local source = {
            adapter={
                cleanup=function()
                    source_cleanups = source_cleanups + 1
                end,
            },
        }

        local ok, failure =
            pcall(context.mount_native_screen, context, function()
            return {
                root={},
                pinned_screen={},
                interaction_target=target,
                subject_source=source,
            }
        end)

        assert.is_false(ok)
        assert.matches('mounted subject adapter is incomplete',
            failure, 1, true)
        assert.equals(1, target_cleanups)
        assert.equals(1, source_cleanups)
        assert.is_nil(context.current)
        assert.equals(0, cleanup.pending_count(registry))
        assert.same({
            current_mount_id=nil,
            active_screen_count=0,
            tracked_screen_count=0,
            owned_screen_count=0,
            borrowed_native_screen_count=0,
            native_attachment_count=1,
            native_screen_dismissal_count=0,
            subject_count=0,
        }, context:cleanup_state())
    end)

    it('cleans native resources when run-scoped initialization fails',
            function()
        local target_cleanups = 0
        local source_cleanups = 0
        context.render_tracker_factory=function()
            error('tracker construction exploded')
        end

        local ok, failure =
            pcall(context.mount_native_screen, context, function()
            return {
                root={},
                pinned_screen={},
                interaction_target={
                    cleanup=function()
                        target_cleanups = target_cleanups + 1
                    end,
                },
                subject_source={
                    adapter={
                        cleanup=function()
                            source_cleanups = source_cleanups + 1
                        end,
                    },
                },
            }
        end)

        assert.is_false(ok)
        assert.matches('DwarfSpec native%-screen mount failed to initialize ' ..
            'run%-scoped state:', failure)
        assert.matches('tracker construction exploded', failure, 1, true)
        assert.equals(1, target_cleanups)
        assert.equals(1, source_cleanups)
        assert.is_nil(context.current)
        assert.equals(0, cleanup.pending_count(registry))
    end)

    it('cleans every partially registered native attachment layer',
            function()
        local cases = {
            {name='detach', failing_push=1},
            {name='subject descriptors', failing_push=2},
            {name='observer restoration', failing_push=3},
        }
        for _, case in ipairs(cases) do
            local root = {kind='native-root-' .. case.name}
            local pinned = {widgets=root}
            local target = interaction_target.new_borrowed_native(pinned, {
                get_current_viewscreen=function() return pinned end,
                invalidate_screen=function() end,
            })
            local source = native_widget_adapter.new_source(root, target, {
                get_widget=function() return nil end,
                get_children=function() return {} end,
                is_container=function() return true end,
            })
            cleanup_push_failure_at =
                cleanup_push_count + case.failing_push

            local ok, failure = pcall(
                context.mount_native_screen, context, function()
                    return {
                        root=root,
                        pinned_screen=pinned,
                        interaction_target=target,
                        subject_source=source,
                    }
                end)

            assert.is_false(ok, case.name)
            assert.matches('injected cleanup registration failure',
                failure, 1, true)
            assert.is_true(target._cleaned, case.name)
            assert.is_true(source.adapter._cleaned, case.name)
            assert.is_nil(context.current, case.name)
            assert.equals(0, cleanup.pending_count(registry), case.name)
            assert.equals(0,
                context:cleanup_state().borrowed_native_screen_count,
                case.name)
            cleanup_push_failure_at = nil
        end
        assert.equals(1, native_observer_installs)
        assert.equals(1, native_observer_restores)
    end)

    it('cleans an observed native attachment when root subject creation fails',
            function()
        local root = {kind='native-root'}
        local pinned = {widgets=root}
        local target = interaction_target.new_borrowed_native(pinned, {
            get_current_viewscreen=function() return pinned end,
            invalidate_screen=function()
                context.current.render_tracker:completed()
            end,
        })
        local source = native_widget_adapter.new_source(root, target, {
            get_widget=function() return nil end,
            get_children=function() return {} end,
            is_container=function() return true end,
        })
        fail_subject = true

        local ok, failure = pcall(
            context.mount_native_screen, context, function()
                return {
                    root=root,
                    pinned_screen=pinned,
                    interaction_target=target,
                    subject_source=source,
                }
            end)

        assert.is_false(ok)
        assert.matches('subject creation exploded', failure, 1, true)
        assert.equals(1, native_observer_installs)
        assert.equals(1, native_observer_restores)
        assert.is_true(target._cleaned)
        assert.is_true(source.adapter._cleaned)
        assert.is_nil(context.current)
        assert.equals(0, cleanup.pending_count(registry))
    end)

    it('cleans native state when initial hierarchy refresh fails', function()
        local root = {kind='native-root'}
        local pinned = {widgets=root}
        local target = interaction_target.new_borrowed_native(pinned, {
            get_current_viewscreen=function() return pinned end,
            invalidate_screen=function() end,
        })
        local source = native_widget_adapter.new_source(root, target, {
            get_widget=function() return nil end,
            get_children=function()
                error('native hierarchy refresh exploded', 0)
            end,
            is_container=function() return true end,
        })

        local ok, failure = pcall(
            context.mount_native_screen, context, function()
                return {
                    root=root,
                    pinned_screen=pinned,
                    interaction_target=target,
                    subject_source=source,
                }
            end)

        assert.is_false(ok)
        assert.matches('native hierarchy refresh exploded',
            failure, 1, true)
        assert.equals(1, native_observer_installs)
        assert.equals(1, native_observer_restores)
        assert.is_true(target._cleaned)
        assert.is_true(source.adapter._cleaned)
        assert.is_nil(context.current)
        assert.equals(0, cleanup.pending_count(registry))
    end)

    it('drains all entries when partial unwind cleanup itself fails',
            function()
        local root = {kind='native-root'}
        local pinned = {widgets=root}
        local target = interaction_target.new_borrowed_native(pinned, {
            get_current_viewscreen=function() return pinned end,
            invalidate_screen=function() end,
        })
        target.cleanup = function()
            error('borrowed target cleanup exploded', 0)
        end
        local source = native_widget_adapter.new_source(root, target, {
            get_widget=function() return nil end,
            get_children=function() return {} end,
            is_container=function() return true end,
        })

        local ok, failure = pcall(
            context.mount_native_screen, context, function()
                return {
                    root=root,
                    pinned_screen=pinned,
                    interaction_target=target,
                    subject_source=source,
                }
            end)

        assert.is_false(ok)
        assert.matches('native-screen mount render capability check failed',
            failure, 1, true)
        assert.matches('cleanup failed:', failure, 1, true)
        assert.matches('borrowed target cleanup exploded',
            failure, 1, true)
        assert.equals(1, native_observer_restores)
        assert.is_true(source.adapter._cleaned)
        assert.is_nil(context.current)
        assert.equals(0, cleanup.pending_count(registry))
        assert.equals(0,
            context:cleanup_state().borrowed_native_screen_count)
    end)

    it('does not create mount state when native acquisition fails',
            function()
        local ok, failure =
            pcall(context.mount_native_screen, context, function()
            error('native acquisition exploded')
        end)

        assert.is_false(ok)
        assert.matches('native acquisition exploded', failure, 1, true)
        assert.equals(0, context.next_mount_id)
        assert.is_nil(context.current)
        assert.equals(0, cleanup.pending_count(registry))
    end)

    it('run cleanup removes the alive mount and all mount entries', function()
        context:mount(TestWidget, {name='lifecycle'})

        assert.is_true(cleanup.run(registry, 'example completion'))

        assert.is_nil(context.current)
        assert.is_false(screens[1].active)
        assert.equals(0, cleanup.pending_count(registry))
    end)

    it('reports every command clearly when there is no current mount',
            function()
        local expected = ' requires a current mount; call ' ..
            'ds.mount(component, options) or ds.mountNativeScreen() first'
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
