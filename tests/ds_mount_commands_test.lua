-- Unit contracts for public mount commands on the run-scoped ds namespace.

local cleanup = assert(loadfile(
    'tests/automation/support/cleanup.lua'))()
local component = assert(loadfile('src/dwarfspec/component.lua'))()
local render_tracker = assert(loadfile(
    'src/dwarfspec/render_tracker.lua'))()
local ds_factory = assert(loadfile(
    'tests/automation/support/ds.lua'))()

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

    before_each(function()
        local Widget = make_class()
        local OverlayWidget = make_class(Widget)
        local ZScreen = make_class()
        TestWidget = make_class(Widget)
        local boundary = component.new({
            Widget=Widget,
            OverlayWidget=OverlayWidget,
            ZScreen=ZScreen,
        })
        local run = {run_id='ds-mount-test', scheduler_state={}}
        registry = cleanup.new(run)
        local scheduler = {run=run}
        local scheduler_module = {
            wait_frames=function() return 1 end,
            wait_until=function(_, _, query) return assert(query()) end,
        }
        ds, reset = ds_factory.new('.',
            {project_root='.', package_root='.'},
            scheduler_module, scheduler, cleanup, registry,
            {settings={}, commands={}}, {
                boundary=boundary,
                render_tracker_factory=function()
                    return render_tracker.new(scheduler_module, scheduler)
                end,
                adapter_factory=function()
                    return {
                        mount=function(_, mount, prepared)
                            screen = {active=true}
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
                'view_id="<root>" from mount 1; no component is currently ' ..
                'mounted')
        reset('before example')
        assert.equals(0, cleanup.pending_count(registry))
    end)

    after_each(function()
        assert.is_true(cleanup.run(registry, 'ds command test teardown'))
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
        assert.equals('child', selected.view_id)
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

    it('reports missing and duplicate IDs with current mount identity',
            function()
        local first = {view_id='duplicate', subviews={}}
        local second = {view_id='duplicate', subviews={}}
        ds.mount(TestWidget, {
            name='selection-errors',
            subviews={first, second},
        })

        local missing_ok, missing = pcall(ds.get, 'missing')
        local duplicate_ok, duplicate = pcall(ds.get, 'duplicate')

        assert.is_false(missing_ok)
        assert.matches('operation="get" mount=1', missing, 1, true)
        assert.matches('selected_view_id="missing" selected_mount=1',
            missing, 1, true)
        assert.matches('view_id="missing" mount=1 was not found',
            missing, 1, true)
        assert.is_false(duplicate_ok)
        assert.matches('selected_view_id="duplicate" selected_mount=1',
            duplicate, 1, true)
        assert.matches('view_id="duplicate" mount=1 matches 2 views',
            duplicate, 1, true)
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
        assert.has_error(function() ds.click() end,
            'DwarfSpec click' .. suffix)
        assert.has_error(function() ds.type('text') end,
            'DwarfSpec type' .. suffix)
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
end)
