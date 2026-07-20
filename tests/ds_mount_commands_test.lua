-- Unit contracts for public mount commands on the run-scoped ds namespace.

local cleanup = assert(loadfile(
    'tests/automation/support/cleanup.lua'))()
local component = assert(loadfile('src/dwarfspec/component.lua'))()
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
        }
        ds = ds_factory.new('.', {project_root='.', package_root='.'},
            scheduler_module, scheduler, cleanup, registry,
            {settings={}, commands={}}, {
                boundary=boundary,
                adapter_factory=function()
                    return {
                        mount=function(_, _, prepared)
                            screen = {active=true}
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
        assert.equals(child, ds.get('child'):raw())
        assert.is_true(screen.active)

        ds.unmount()

        assert.is_false(screen.active)
        assert.equals(0, cleanup.pending_count(registry))
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
end)
