-- Unit contracts for public mount commands on the run-scoped ds namespace.

local cleanup = assert(loadfile(
    'src/dwarfspec/automation/cleanup.lua'))()
local component = assert(loadfile('src/dwarfspec/component.lua'))()
local render_tracker = assert(loadfile(
    'src/dwarfspec/render_tracker.lua'))()
local ds_factory = assert(loadfile(
    'src/dwarfspec/ds.lua'))()
local interaction_target = assert(loadfile(
    'src/dwarfspec/interaction_target.lua'))()
local lua_view_adapter = assert(loadfile(
    'src/dwarfspec/lua_view_adapter.lua'))()
local EventType = require('dwarfspec.automation.event_types')
local EMouseButton = require('dwarfspec.mouse_buttons')
local EInputState = require('dwarfspec.input_states')
local TestStatus = require('dwarfspec.automation.test_statuses')

---Creates a minimal callable class with DFHack defclass-compatible shape.
---@param parent table|nil
---@return table
local function make_class(parent)
    local class = {ATTRS={}}
    class.__index = class
    class.super = parent
    setmetatable(class, {
        __index=parent,
        __call=function(self, attributes)
            local instance = {}
            for key, value in pairs(attributes or {}) do
                instance[key] = value
            end
            return setmetatable(instance, self)
        end,
    })
    return class
end

---Creates one injected native widget fixture with exact ordered children.
---@param name string|nil
---@param type_name string
---@param children table[]|nil
---@param fields table|nil
---@return table
local function make_native_widget(name, type_name, children, fields)
    local widget = {
        name=name,
        _type={_name=type_name},
        children=children or {},
    }
    for key, value in pairs(fields or {}) do widget[key] = value end
    return widget
end

describe('DwarfSpec public mount commands', function()
    local ds
    local registry
    local reset
    local screen
    local native_screen
    local native_root
    local current_native_screen
    local native_df_screen
    local run
    local TestWidget
    local published
    local current_tracker
    local original_dfhack
    local original_df
    local original_gui
    local simulated_inputs
    local wait_until_calls
    local component_mount_calls
    local native_widget_lookup_calls

    before_each(function()
        original_dfhack = rawget(_G, 'dfhack')
        original_df = rawget(_G, 'df')
        original_gui = package.loaded.gui
        screen = nil
        component_mount_calls = 0
        native_widget_lookup_calls = 0
        simulated_inputs = {}
        wait_until_calls = 0
        rawset(_G, 'dfhack', {
            screen={
                getMousePos=function() return 90, 91 end,
                getWindowSize=function() return 80, 25 end,
            },
            gui={
                getWidget=function(parent, segment)
                    native_widget_lookup_calls =
                        native_widget_lookup_calls + 1
                    local children = parent.children or {}
                    if type(segment) == 'number' then
                        return children[segment + 1]
                    end
                    for _, child in ipairs(children) do
                        if child.name == segment then return child end
                    end
                    return nil
                end,
                getWidgetChildren=function(parent)
                    local result = {}
                    for index, child in ipairs(parent.children or {}) do
                        result[index] = child
                    end
                    return result
                end,
            },
        })
        rawset(_G, 'df', {
            global={
                gps={mouse_x=4, mouse_y=5},
                enabler={
                    mouse_focus=false,
                    tracking_on=0,
                    mouse_lbut_down=0,
                    mouse_lbut_lift=0,
                    mouse_rbut_down=0,
                    mouse_rbut_lift=0,
                    mouse_mbut_down=0,
                    mouse_mbut_lift=0,
                },
            },
        })
        package.loaded.gui = {
            simulateInput=function(native_screen, key)
                table.insert(simulated_inputs, {
                    screen=native_screen,
                    key=key,
                    x=df.global.gps.mouse_x,
                    y=df.global.gps.mouse_y,
                    mouse_focus=df.global.enabler.mouse_focus,
                    tracking_on=df.global.enabler.tracking_on,
                    left_down=df.global.enabler.mouse_lbut_down,
                    left_lift=df.global.enabler.mouse_lbut_lift,
                    right_down=df.global.enabler.mouse_rbut_down,
                    right_lift=df.global.enabler.mouse_rbut_lift,
                    middle_down=df.global.enabler.mouse_mbut_down,
                    middle_lift=df.global.enabler.mouse_mbut_lift,
                })
                current_tracker:completed()
            end,
        }
        local Widget = make_class()
        local OverlayWidget = make_class(Widget)
        local ZScreen = make_class()
        TestWidget = make_class(Widget)
        local boundary = component.new({
            Widget=Widget,
            OverlayWidget=OverlayWidget,
            ZScreen=ZScreen,
        })
        published = {}
        local now = 10
        run = {
            run_id='ds-mount-test',
            scheduler_state={},
            event_publisher={
                now_ms=function()
                    now = now + 2
                    return now
                end,
                publish=function(event_type, payload)
                    table.insert(published, {
                        type=event_type,
                        payload=payload,
                    })
                end,
            },
        }
        registry = cleanup.new(run)
        local scheduler = {run=run}
        local scheduler_module = {
            wait_frames=function() return 1 end,
            wait_until=function(_, _, query)
                wait_until_calls = wait_until_calls + 1
                local result = query()
                if not result and current_tracker then
                    current_tracker:completed()
                    result = query()
                end
                return assert(result)
            end,
        }
        native_root = {
            kind='native-widget-root',
            _type={_name='df.widget_container'},
            children={},
        }
        native_screen = {
            name='native-screen',
            widgets=native_root,
            show_calls=0,
            dismiss_calls=0,
            resize_calls=0,
            replace_calls=0,
            navigation_calls=0,
        }
        current_native_screen = native_screen
        native_df_screen = native_screen
        ds, reset = ds_factory.new('.',
            {project_root='.', package_root='.'},
            scheduler_module, scheduler, cleanup, registry,
            {settings={}, commands={
                sample_success={
                    callback=function(_, value) return 'ok:' .. value end,
                },
                sample_failure={
                    callback=function() error('deliberate command failure') end,
                },
            }}, {
                boundary=boundary,
                current_viewscreen=function()
                    return current_native_screen
                end,
                native_viewscreen=function() return native_df_screen end,
                is_native_widget_root=function(root)
                    return root == native_root
                end,
                invalidate_native_screen=function()
                    current_tracker:completed()
                end,
                render_tracker_factory=function()
                    current_tracker = render_tracker.new(
                        scheduler_module, scheduler)
                    return current_tracker
                end,
                adapter_factory=function()
                    return {
                        mount=function(_, mount, prepared)
                            component_mount_calls =
                                component_mount_calls + 1
                            screen = {
                                active=true,
                                invalidation_count=0,
                                _native=native_screen,
                                isActive=function(self) return self.active end,
                                ---Records an invalidation and its render.
                                ---@param self table
                                invalidate=function(self)
                                    self.invalidation_count =
                                        self.invalidation_count + 1
                                    current_tracker:completed()
                                end,
                            }
                            mount.render_tracker:completed()
                            return {
                                root=prepared.component,
                                host_screen=screen,
                                interaction_target=
                                    interaction_target.new_owned_screen(
                                        screen, {
                                            is_active=function(candidate)
                                                return candidate:isActive()
                                            end,
                                            resolve_native_screen=
                                                function(candidate)
                                                    return ds_factory.resolve_native_screen(
                                                        candidate, function()
                                                            return native_screen
                                                        end)
                                                end,
                                        }),
                                subject_source=
                                    lua_view_adapter.new_source(
                                        prepared.component),
                            }
                        end,
                        unmount=function()
                            screen.active = false
                        end,
                    }
                end,
            })
    end)

    it('resets the implicit mount before and after examples idempotently',
            function()
        local mounted = ds.mount(TestWidget, {name='reset-root'})

        reset('after example')

        assert.is_false(screen.active)
        assert.equals(0, cleanup.pending_count(registry))
        assert.has_error(function() mounted:raw() end,
            'DwarfSpec subject raw access rejected stale subject ' ..
            'control_path="<root>" from mount 1; no component is currently ' ..
                'mounted')
        reset('before example')
        assert.equals(0, cleanup.pending_count(registry))
    end)

    after_each(function()
        local cleanup_ok = cleanup.run(registry, 'ds command test teardown')
        package.loaded.gui = original_gui
        rawset(_G, 'dfhack', original_dfhack)
        rawset(_G, 'df', original_df)
        assert.is_true(cleanup_ok)
        assert.equals(0, cleanup.pending_count(registry))
        if screen then assert.is_false(screen.active) end
    end)

    it('mounts, selects from, roots, and unmounts the implicit component',
            function()
        local child = {view_id='child', subviews={}}
        local mounted = ds.mount(TestWidget, {
            name='root',
            subviews={child, child=child},
        })

        assert.equals('native', ds.ESubjectSource.NATIVE)
        assert.equals('overlay', ds.ESubjectSource.OVERLAY)
        assert.equals('root', mounted:raw().name)
        assert.equals(mounted:raw(), ds.root():raw())
        local selected = ds.get('child')
        assert.equals(child, selected:raw())
        assert.equals('child', selected.control_path)
        local tree = ds.capture_view_tree('implicit-tree')
        assert.equals('child', tree.children[1].view_id)
        assert.is_true(screen.active)

        ds.unmount()

        assert.is_false(screen.active)
        assert.equals(0, cleanup.pending_count(registry))
    end)

    it('requires explicit unmount before mounting another component',
            function()
        local first = ds.mount(TestWidget, {name='first'})
        local first_screen = screen

        assert.has_error(function()
            ds.mount(TestWidget, {name='second'})
        end, 'DwarfSpec mount rejected because mount 1 is still current; ' ..
            'call ds.unmount() before mounting another component')
        assert.is_true(first_screen.active)
        assert.equals('first', first:raw().name)

        ds.unmount()
        local second = ds.mount(TestWidget, {name='second'})

        assert.is_false(first_screen.active)
        assert.is_true(screen.active)
        assert.equals('second', second:raw().name)
    end)

    it('attaches non-owningly only when the component argument is missing',
            function()
        local mounted = ds.mount()

        assert.equals(native_root, mounted:raw())
        assert.equals(native_root, ds.root():raw())
        ds.input('SELECT')
        assert.equals(native_screen, simulated_inputs[1].screen)
        assert.equals('SELECT', simulated_inputs[1].key)
        assert.equals(0, component_mount_calls)
        assert.is_nil(screen)
        assert.same({
            current_mount_id=1,
            active_screen_count=0,
            tracked_screen_count=0,
            subject_count=2,
            pointer_active=false,
        }, run.mount_cleanup_probe())
        assert.has_error(function()
            ds.viewport(80, 25)
        end, 'DwarfSpec viewport is unavailable for a non-owning ' ..
            'native-screen mount')
        assert.same({
            show_calls=0,
            dismiss_calls=0,
            resize_calls=0,
            replace_calls=0,
            navigation_calls=0,
        }, {
            show_calls=native_screen.show_calls,
            dismiss_calls=native_screen.dismiss_calls,
            resize_calls=native_screen.resize_calls,
            replace_calls=native_screen.replace_calls,
            navigation_calls=native_screen.navigation_calls,
        })

        ds.unmount()

        assert.is_nil(run.mount_cleanup_probe().current_mount_id)
        assert.equals(0, run.mount_cleanup_probe().tracked_screen_count)
        assert.equals(0, native_screen.dismiss_calls)
        assert.has_error(function() mounted:raw() end,
            'DwarfSpec subject raw access rejected stale subject ' ..
            'control_path="<root>" from mount 1; no component is currently ' ..
                'mounted')
        assert.has_error(function() ds.mount(nil) end,
            'unsupported component input (nil); expected a DFHack defclass ' ..
                'derived from widgets.Widget, overlay.OverlayWidget, or ' ..
                'gui.ZScreen, or an instance of one of those classes')
    end)

    it('rejects native subject access immediately after a screen transition',
            function()
        local mounted = ds.mount()
        current_native_screen = {
            name='next-native-screen',
            widgets={kind='next-widget-root'},
        }

        assert.has_error(function() mounted:raw() end,
            'DwarfSpec native subject resolution rejected stale ' ..
            'native-screen mount; pinned viewscreen is no longer current')
        assert.equals(0, native_screen.dismiss_calls)
    end)

    it('resolves native named, indexed, mixed, and slash-bearing paths',
            function()
        local slash = make_native_widget(
            'Right/panel', 'df.widget_textst')
        local row = make_native_widget(nil, 'df.widget_container', {slash})
        local tabs = make_native_widget(
            'Tabs', 'df.widget_container', {row})
        local hidden = make_native_widget(
            'Hidden', 'df.widget_textst', nil, {
                visible=false,
            })
        local inactive = make_native_widget(
            'Inactive', 'df.widget_textst', nil, {
                active=false,
            })
        native_root.children = {tabs, hidden, inactive}
        ds.mount()

        local named = ds.get('Tabs')
        local lookup_count = native_widget_lookup_calls
        assert.equals(tabs, named:raw())
        assert.equals(lookup_count + 1, native_widget_lookup_calls)
        assert.equals(tabs, ds.get({0}):raw())
        local mixed = ds.get({'Tabs', 0, 'Right/panel'})
        assert.equals(slash, mixed:raw())
        assert.equals(
            '{"Tabs", 0, "Right/panel"}', mixed.control_path)
        assert.equals(hidden, ds.get('Hidden'):raw())
        assert.equals(inactive, ds.get('Inactive'):raw())
    end)

    it('uses clipped native bounds and rejects unusable pointer subjects',
            function()
        local partial = make_native_widget(
            'Partial', 'df.widget', nil, {
                rect={x1=-3, y1=4, x2=6, y2=10},
                flag={
                    VISIBILITY_VISIBLE=true,
                    VISIBILITY_ACTIVE=true,
                },
            })
        local invalid = make_native_widget(
            'Invalid', 'df.widget', nil, {
                rect={x1=7, y1=9, x2=3, y2=11},
                flag={
                    VISIBILITY_VISIBLE=true,
                    VISIBILITY_ACTIVE=true,
                },
            })
        local offscreen = make_native_widget(
            'Offscreen', 'df.widget', nil, {
                rect={x1=90, y1=30, x2=100, y2=40},
                flag={
                    VISIBILITY_VISIBLE=true,
                    VISIBILITY_ACTIVE=true,
                },
            })
        native_root.children = {partial, invalid, offscreen}
        ds.mount()

        assert.same({0, 4}, {
            ds.move_pointer(ds.get('Partial'), 'top_left'),
        })
        assert.has_error(function()
            ds.move_pointer(ds.get('Invalid'))
        end, 'view has no usable live bounds for pointer placement')
        assert.has_error(function()
            ds.move_pointer(ds.get('Offscreen'))
        end, 'view has no usable live bounds for pointer placement')
        assert.same({x1=90, y1=30, x2=100, y2=40},
            ds.get('Offscreen'):inspect().body)
    end)

    it('makes a retained native subject stale after removal', function()
        local original = make_native_widget(
            'Status', 'df.widget_textst')
        native_root.children = {original}
        ds.mount()
        local selected = ds.get('Status')
        native_root.children = {}

        assert.has_error(function() selected:raw() end,
            'DwarfSpec subject raw access rejected stale native subject ' ..
            'path={"Status"} mount=1 because the widget no longer resolves; ' ..
                'call ds.get(path) to select it again')
    end)

    it('requires a new native subject after same-path replacement', function()
        local original = make_native_widget(
            'Status', 'df.widget_textst')
        native_root.children = {original}
        ds.mount()
        local selected = ds.get('Status')
        local replacement = make_native_widget(
            'Status', 'df.widget_textst')
        native_root.children = {replacement}

        assert.has_error(function() selected:raw() end,
            'DwarfSpec subject raw access rejected stale native subject ' ..
            'path={"Status"} mount=1 because the widget was replaced; call ' ..
                'ds.get(path) to select the replacement')
        assert.equals(replacement, ds.get('Status'):raw())
    end)

    it('reports bounded native child diagnostics for missing paths',
            function()
        for index = 0, 14 do
            table.insert(native_root.children, make_native_widget(
                ('Child%02d'):format(index), 'df.widget_textst'))
        end
        ds.mount()

        local ok, failure = pcall(ds.get, 'Missing')

        assert.is_false(ok)
        assert.matches('native_path={"Missing"}', failure, 1, true)
        assert.matches('missing segment%[1%]="Missing"', failure)
        assert.matches('parent_name="<native%-root>"', failure)
        assert.matches('parent_type="df.widget_container"',
            failure, 1, true)
        assert.matches('named children=%[', failure)
        assert.matches('indexed children=%[', failure)
        assert.matches('%.%.%. %(%+3 more%)', failure)
    end)

    it('reports missing control paths with current mount identity',
            function()
        ds.mount(TestWidget, {
            name='selection-errors',
            subviews={},
        })

        local missing_ok, missing = pcall(ds.get, 'missing')

        assert.is_false(missing_ok)
        assert.matches('operation="get" mount=1', missing, 1, true)
        assert.matches('selected_control_path="missing" selected_mount=1',
            missing, 1, true)
        assert.matches('control_path="missing" mount=1 missing segment="missing"',
            missing, 1, true)
    end)

    it('rejects duplicate direct child IDs while mounting', function()
        local first = {view_id='duplicate', subviews={}}
        local second = {view_id='duplicate', subviews={}}

        local mounted, failure = pcall(ds.mount, TestWidget,
            {subviews={first, second}})
        assert.is_false(mounted)
        assert.matches('DwarfSpec invalid component tree: parent ' ..
            'control_path="<root>" has multiple direct children with ' ..
            'view_id="duplicate"', failure, 1, true)
    end)

    it('reports public commands clearly without a current mount', function()
        local suffix = ' requires a mounted component; call ' ..
            'ds.mount(component, options) first'
        assert.has_error(function() ds.root() end,
            'DwarfSpec root' .. suffix)
        assert.has_error(function() ds.get('missing') end,
            'DwarfSpec get' .. suffix)
        assert.has_error(function() ds.unmount() end,
            'DwarfSpec unmount' .. suffix)
        assert.has_error(function() ds.inspect() end,
            'DwarfSpec inspect' .. suffix)
        assert.has_error(function() ds.redraw() end,
            'DwarfSpec redraw' .. suffix)
        assert.has_error(function() ds.move_pointer() end,
            'DwarfSpec move_pointer' .. suffix)
        assert.has_error(function() ds.input('SELECT') end,
            'DwarfSpec input' .. suffix)
        assert.has_error(function()
            ds.mouseInput(EMouseButton.LEFT, EInputState.CLICK)
        end, 'DwarfSpec mouseInput' .. suffix)
        assert.has_error(function() ds.click() end,
            'DwarfSpec click' .. suffix)
        assert.has_error(function() ds.type('text') end,
            'DwarfSpec type' .. suffix)
    end)

    it('redraws the subject screen and waits by default', function()
        local mounted = ds.mount(TestWidget)
        local baseline_waits = wait_until_calls

        assert.equals(mounted, mounted:redraw())

        assert.equals(1, screen.invalidation_count)
        assert.equals(baseline_waits + 1, wait_until_calls)
    end)

    it('can redraw without waiting for the resulting render', function()
        local mounted = ds.mount(TestWidget)
        local baseline_waits = wait_until_calls

        assert.equals(mounted, mounted:redraw({wait=false}))

        assert.equals(1, screen.invalidation_count)
        assert.equals(baseline_waits, wait_until_calls)
    end)

    it('validates redraw options', function()
        local mounted = ds.mount(TestWidget)

        local cases = {
            {
                options=false,
                expected='redraw options must be a table',
            },
            {
                options={wait='yes'},
                expected='redraw wait option must be a boolean',
            },
            {
                options={unknown=true},
                expected='unsupported redraw option: unknown',
            },
        }
        for _, case in ipairs(cases) do
            local ok, failure = pcall(
                mounted.redraw, mounted, case.options)

            assert.is_false(ok)
            assert.matches(case.expected, failure, 1, true)
        end
    end)

    it('rejects redraw through a stale subject', function()
        local mounted = ds.mount(TestWidget)
        ds.unmount()

        local ok, failure = pcall(mounted.redraw, mounted)

        assert.is_false(ok)
        assert.matches('DwarfSpec redraw rejected stale subject',
            failure, 1, true)
        assert.matches('no component is currently mounted',
            failure, 1, true)
    end)

    it('sends button and wheel input at the current pointer position',
            function()
        local mounted = ds.mount(TestWidget, {
            frame_body={x1=10, y1=20, x2=14, y2=24},
        })
        assert.equals(EMouseButton.LEFT, ds.EMouseButton.LEFT)
        assert.equals(EMouseButton.SCROLL_DOWN,
            ds.EMouseButton.SCROLL_DOWN)
        assert.equals(EInputState.CLICK, ds.EInputState.CLICK)
        assert.is_nil(ds.EMouseInput)
        assert.has_error(function()
            ds.mouseInput(EMouseButton.LEFT)
        end, 'mouse input requires a pointer position; call ' ..
            'ds.move_pointer() or subject:hover() first')

        mounted:hover('top_left')
        for _, input in ipairs({
                {EMouseButton.LEFT},
                {EMouseButton.RIGHT},
                {EMouseButton.MIDDLE},
                {EMouseButton.SCROLL_UP},
                {EMouseButton.SCROLL_DOWN}}) do
            ds.mouseInput(input[1], input[2])
        end

        assert.same({
            '_MOUSE_L',
            '_MOUSE_R',
            '_MOUSE_M',
            'CONTEXT_SCROLL_UP',
            'CONTEXT_SCROLL_DOWN',
        }, {
            simulated_inputs[1].key,
            simulated_inputs[2].key,
            simulated_inputs[3].key,
            simulated_inputs[4].key,
            simulated_inputs[5].key,
        })
        for _, input in ipairs(simulated_inputs) do
            assert.equals('native-screen', input.screen.name)
            assert.same({10, 20}, {input.x, input.y})
            assert.is_true(input.mouse_focus)
            assert.equals(1, input.tracking_on)
        end
        assert.same({10, 20}, {dfhack.screen.getMousePos()})
        assert.same({4, 5}, {
            df.global.gps.mouse_x,
            df.global.gps.mouse_y,
        })
        assert.is_false(df.global.enabler.mouse_focus)
        assert.equals(0, df.global.enabler.tracking_on)
        assert.has_error(function() ds.mouseInput('unknown') end,
            'unsupported mouse button: unknown')
        assert.has_error(function()
            ds.mouseInput(EMouseButton.LEFT, 'unknown')
        end, 'unsupported mouse button action: unknown')
        assert.has_error(function()
            ds.mouseInput(EMouseButton.SCROLL_DOWN,
                EInputState.CLICK)
        end, 'mouse wheel input does not accept a button action')
    end)

    it('persists explicit button-down state until matching button-up input',
            function()
        local mounted = ds.mount(TestWidget, {
            frame_body={x1=10, y1=20, x2=14, y2=24},
        })
        mounted:move_pointer('top_left')

        local transitions = {
            {
                button=EMouseButton.LEFT,
                key='_MOUSE_L_DOWN',
                down_field='mouse_lbut_down',
                lift_field='mouse_lbut_lift',
                record_down='left_down',
                record_lift='left_lift',
            },
            {
                button=EMouseButton.RIGHT,
                key='_MOUSE_R_DOWN',
                down_field='mouse_rbut_down',
                lift_field='mouse_rbut_lift',
                record_down='right_down',
                record_lift='right_lift',
            },
            {
                button=EMouseButton.MIDDLE,
                key='_MOUSE_M_DOWN',
                down_field='mouse_mbut_down',
                lift_field='mouse_mbut_lift',
                record_down='middle_down',
                record_lift='middle_lift',
            },
        }

        for _, transition in ipairs(transitions) do
            ds.mouseInput(transition.button, EInputState.DOWN)
            local down_input = simulated_inputs[#simulated_inputs]
            assert.equals(transition.key, down_input.key)
            assert.equals(1, down_input[transition.record_down])
            assert.equals(0, down_input[transition.record_lift])
            assert.equals(1, df.global.enabler[transition.down_field])
            assert.is_true(df.global.enabler.mouse_focus)
            assert.equals(1, df.global.enabler.tracking_on)

            mounted:move_pointer('bottom_right')
            assert.equals(1, df.global.enabler[transition.down_field])

            ds.mouseInput(transition.button, EInputState.UP)
            local up_input = simulated_inputs[#simulated_inputs]
            assert.is_nil(up_input.key)
            assert.equals(0, up_input[transition.record_down])
            assert.equals(1, up_input[transition.record_lift])
            assert.equals(0, df.global.enabler[transition.down_field])
            assert.equals(0, df.global.enabler[transition.lift_field])
            assert.is_false(df.global.enabler.mouse_focus)
            assert.equals(0, df.global.enabler.tracking_on)
        end
    end)

    it('routes input to a native child while retaining the mounted root',
            function()
        local root_native = {name='root'}
        local child_native = {name='child', parent=root_native}
        local unrelated = {name='unrelated'}

        assert.equals(child_native, ds_factory.resolve_native_screen(
            {_native=root_native}, function() return child_native end))
        assert.equals(root_native, ds_factory.resolve_native_screen(
            {_native=root_native}, function() return unrelated end))
        assert.equals(root_native, ds_factory.resolve_native_screen(
            {_native=root_native}, function() error('unavailable') end))
    end)

    it('publishes structured command results and bounded diagnostics',
            function()
        assert.equals('ok:value', ds.sample_success('value'))
        local ok, failure = pcall(ds.sample_failure)

        assert.is_false(ok)
        assert.matches('deliberate command failure', failure, 1, true)
        assert.equals(EventType.COMMAND_STARTED, published[1].type)
        assert.equals('sample_success', published[1].payload.name)
        assert.equals(EventType.COMMAND_FINISHED, published[2].type)
        assert.equals(TestStatus.SUCCESS, published[2].payload.status)
        assert.equals(2, published[2].payload.duration_ms)
        assert.equals(EventType.COMMAND_STARTED, published[3].type)
        assert.equals(EventType.COMMAND_FINISHED, published[4].type)
        assert.equals(TestStatus.ERROR, published[4].payload.status)
        assert.equals(EventType.DIAGNOSTIC_RECORDED, published[5].type)
        assert.equals('command_failure', published[5].payload.kind)
        assert.matches('deliberate command failure',
            published[5].payload.content.message, 1, true)
    end)
end)
