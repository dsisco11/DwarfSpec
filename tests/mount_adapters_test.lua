-- Unit contracts for live component adapter ownership and interception.

local mount_adapters = assert(loadfile(
    'src/dwarfspec/mount_adapters.lua'))()
local instrumentation = assert(loadfile(
    'src/dwarfspec/render_instrumentation.lua'))()

---Creates a minimal class compatible with the adapter's host requirements.
---@param parent table
---@return table
local function define_class(_, parent)
    local class = {super=parent}
    class.__index = class
    class.ATTRS = function() end
    setmetatable(class, {
        __index=parent,
        __call=function(self, attributes)
            local instance = {
                active=false,
                subviews={},
            }
            for key, value in pairs(attributes or {}) do
                instance[key] = value
            end
            setmetatable(instance, self)
            if instance.init then instance:init(attributes or {}) end
            return instance
        end,
    })
    return class
end

---Creates a screen base that renders immediately when shown.
---@return table
local function screen_base()
    return {
        addviews=function(self, views)
            for _, view in ipairs(views) do
                table.insert(self.subviews, view)
                view.parent_view = self
            end
        end,
        onRender=function(self)
            self.render_calls = (self.render_calls or 0) + 1
            return 'rendered'
        end,
        show=function(self, parent)
            self.shown_parent = parent
            self.active = true
            self:onResize(80, 25)
            self:onRender()
        end,
        onResize=function(self, width, height)
            self.layout_width = width
            self.layout_height = height
            for _, view in ipairs(self.subviews) do
                view.frame_body = {width=width, height=height}
            end
        end,
        dismiss=function(self)
            self.active = false
        end,
        isActive=function(self)
            return self.active
        end,
    }
end

---Creates a render tracker double.
---@return table
local function tracker_double()
    return {
        completions=0,
        failures={},
        completed=function(self)
            self.completions = self.completions + 1
        end,
        failed=function(self, failure)
            table.insert(self.failures, failure)
        end,
    }
end

describe('DwarfSpec mount adapters', function()
    local factory
    local last_overlay_controller

    before_each(function()
        factory = mount_adapters.new({
            gui_module={ZScreen=screen_base()},
            define_class=define_class,
            instrumentation=instrumentation,
            enrich_failure=function(_, operation, failure)
                return operation .. ': ' .. failure
            end,
            overlay_factory={
                create=function(_, mount, widget, options)
                    local controller = {
                        mount=mount,
                        widget=widget,
                        options=options,
                        calls={},
                    }
                    for _, name in ipairs({
                        'layout', 'render', 'update', 'enable',
                        'disable', 'restore',
                    }) do
                        controller[name] = function(self)
                            table.insert(self.calls, name)
                        end
                    end
                    controller.input = function(self, keys)
                        table.insert(self.calls, 'input')
                        self.keys = keys
                        return true
                    end
                    last_overlay_controller = controller
                    return controller
                end,
            },
        })
    end)

    it('hosts widgets on an instrumented owned screen', function()
        for _, category in ipairs({'widget'}) do
            local tracker = tracker_double()
            local mount = {
                id=1,
                render_tracker=tracker,
                refresh_calls=0,
            }
            mount.refresh_views = function()
                mount.refresh_calls = mount.refresh_calls + 1
            end
            local component_class = {}
            local component = setmetatable({focus_group={}}, component_class)
            local cleanups = {}
            local backing = {child={}}

            local result = factory(category):mount(mount,
                {
                    component=component,
                    options={
                        initial_pause=false,
                        viewport={width=40, height=20},
                        backing_viewscreen=backing,
                    },
                }, function(name, action)
                    table.insert(cleanups, {name=name, action=action})
                end)

            assert.equals(component, result.root)
            assert.not_equals(component, result.host_screen)
            assert.equals(component, result.host_screen.subviews[1])
            assert.is_true(result.host_screen.active)
            assert.is_false(result.host_screen.initial_pause)
            assert.equals(backing, result.host_screen.shown_parent)
            assert.equals(40, result.host_screen.layout_width)
            assert.equals(20, result.host_screen.layout_height)
            assert.equals(40, component.frame_body.width)
            assert.equals(1, tracker.completions)
            assert.equals(1, mount.refresh_calls)
            assert.is_nil(rawget(component_class, 'onRender'))
            assert.equals(2, #cleanups)
            assert.matches('restore component render interception',
                cleanups[1].name, 1, true)
            assert.matches('dismiss component screen', cleanups[2].name,
                1, true)

            cleanups[2].action()
            cleanups[1].action()
            assert.is_false(result.host_screen.active)
            assert.is_nil(rawget(result.host_screen, 'onRender'))
            assert.is_nil(rawget(component_class, 'onRender'))
        end
    end)

    it('routes overlay lifecycle through the generic owned host', function()
        local tracker = tracker_double()
        local mount = {
            id=3,
            render_tracker=tracker,
            refresh_views=function() end,
        }
        local component = {focus_group={}}
        local backing = {kind='backing'}
        local cleanups = {}
        local result = factory('overlay'):mount(mount, {
            component=component,
            options={
                initial_pause=true,
                backing_viewscreen=backing,
            },
        }, function(name, action)
            table.insert(cleanups, {name=name, action=action})
        end)

        assert.equals(component, result.root)
        assert.equals(component, result.host_screen.subviews[1])
        assert.equals(backing, result.host_screen.shown_parent)
        assert.equals(last_overlay_controller,
            result.host_screen.overlay_controller)
        assert.same({'enable', 'layout'},
            last_overlay_controller.calls)
        result.host_screen:renderSubviews({})
        result.host_screen:onIdle()
        assert.is_true(result.host_screen:inputToSubviews({SELECT=true}))
        assert.same({'enable', 'layout', 'render', 'update', 'input'},
            last_overlay_controller.calls)
        assert.equals(4, #cleanups)
        assert.matches('restore overlay component state',
            cleanups[1].name, 1, true)
        assert.matches('disable overlay component',
            cleanups[4].name, 1, true)

        for index=#cleanups,1,-1 do cleanups[index].action() end
        assert.same({
            'enable', 'layout', 'render', 'update', 'input',
            'disable', 'restore',
        }, last_overlay_controller.calls)
        assert.is_false(result.host_screen.active)
    end)

    it('instruments and restores a complete screen instance', function()
        local base = screen_base()
        local original = function(self)
            self.original_called = true
        end
        local screen = setmetatable({
            active=false,
            subviews={},
            onRender=original,
        }, {__index=base})
        local tracker = tracker_double()
        local mount = {id=2, render_tracker=tracker}
        local cleanups = {}

        local result = factory('screen'):mount(mount, {component=screen},
            function(_, action) table.insert(cleanups, action) end)

        assert.equals(screen, result.root)
        assert.equals(screen, result.host_screen)
        assert.is_true(screen.original_called)
        assert.equals(1, tracker.completions)
        cleanups[2]()
        cleanups[1]()
        assert.equals(original, rawget(screen, 'onRender'))
    end)
end)
