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
        show=function(self)
            self.active = true
            self:onRender()
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

    before_each(function()
        factory = mount_adapters.new({
            gui_module={ZScreen=screen_base()},
            define_class=define_class,
            instrumentation=instrumentation,
            enrich_failure=function(_, operation, failure)
                return operation .. ': ' .. failure
            end,
        })
    end)

    it('hosts widgets and overlays on an instrumented owned screen', function()
        for _, category in ipairs({'widget', 'overlay'}) do
            local tracker = tracker_double()
            local mount = {id=1, render_tracker=tracker}
            local component = {focus_group={}}
            local cleanups = {}

            local result = factory(category):mount(mount,
                {component=component}, function(name, action)
                    table.insert(cleanups, {name=name, action=action})
                end)

            assert.equals(component, result.root)
            assert.not_equals(component, result.host_screen)
            assert.equals(component, result.host_screen.subviews[1])
            assert.is_true(result.host_screen.active)
            assert.equals(1, tracker.completions)
            assert.equals(2, #cleanups)
            assert.matches('restore component render interception',
                cleanups[1].name, 1, true)
            assert.matches('dismiss component screen', cleanups[2].name,
                1, true)

            cleanups[2].action()
            cleanups[1].action()
            assert.is_false(result.host_screen.active)
            assert.is_nil(rawget(result.host_screen, 'onRender'))
        end
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
