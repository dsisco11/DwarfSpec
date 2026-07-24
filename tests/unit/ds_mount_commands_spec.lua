-- Unit contracts for public mount commands on the run-scoped ds namespace.

local cleanup = assert(loadfile(
    'src/dwarfspec/automation/cleanup.lua'))()
local component = assert(loadfile('src/dwarfspec/component.lua'))()
local render_tracker = assert(loadfile(
    'src/dwarfspec/render_tracker.lua'))()
local ds_factory = assert(loadfile(
    'tests/automation/support/ds.lua'))()
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

describe('DwarfSpec public mount commands', function()
    local ds
    local registry
    local reset
    local screen
    local TestWidget
    local published
    local current_tracker
    local original_dfhack
    local original_df
    local original_gui
    local simulated_inputs

    before_each(function()
        original_dfhack = rawget(_G, 'dfhack')
        original_df = rawget(_G, 'df')
        original_gui = package.loaded.gui
        simulated_inputs = {}
        rawset(_G, 'dfhack', {
            screen={getMousePos=function() return 90, 91 end},
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
        local run = {
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
                local result = query()
                if not result and current_tracker then
                    current_tracker:completed()
                    result = query()
                end
                return assert(result)
            end,
        }
        local native_screen = {name='native-screen'}
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
                current_viewscreen=function() return native_screen end,
                render_tracker_factory=function()
                    current_tracker = render_tracker.new(
                        scheduler_module, scheduler)
                    return current_tracker
                end,
                adapter_factory=function()
                    return {
                        mount=function(_, mount, prepared)
                            screen = {
                                active=true,
                                _native=native_screen,
                                isActive=function(self) return self.active end,
                            }
                            mount.render_tracker:completed()
                            return {
                                root=prepared.component,
                                host_screen=screen,
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
