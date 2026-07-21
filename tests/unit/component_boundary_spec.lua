-- Executable contracts for supported live component inputs.

local component = assert(loadfile('src/dwarfspec/component.lua'))()

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

describe('DwarfSpec component boundary', function()
    local Widget
    local OverlayWidget
    local ZScreen
    local PlainWidget
    local TestOverlay
    local TestScreen
    local boundary

    before_each(function()
        Widget = make_class()
        OverlayWidget = make_class(Widget)
        ZScreen = make_class()
        PlainWidget = make_class(Widget)
        TestOverlay = make_class(OverlayWidget)
        TestScreen = make_class(ZScreen)
        boundary = component.new({
            Widget=Widget,
            OverlayWidget=OverlayWidget,
            ZScreen=ZScreen,
        })
    end)

    it('classifies and constructs all supported component classes', function()
        local cases = {
            {class=PlainWidget, category='widget'},
            {class=TestOverlay, category='overlay'},
            {class=TestScreen, category='screen'},
        }
        for _, case in ipairs(cases) do
            local prepared = boundary:prepare(case.class, {marker=case.category})
            assert.equals(case.category, prepared.category)
            assert.equals('class', prepared.input_form)
            assert.equals(case.category, prepared.component.marker)
            assert.equals(case.class, getmetatable(prepared.component))
        end
    end)

    it('classifies already-created instances without reconstructing them',
            function()
        local cases = {
            {instance=PlainWidget(), category='widget'},
            {instance=TestOverlay(), category='overlay'},
            {instance=TestScreen(), category='screen'},
        }
        for _, case in ipairs(cases) do
            local prepared = boundary:prepare(case.instance)
            assert.equals(case.category, prepared.category)
            assert.equals('instance', prepared.input_form)
            assert.equals(case.instance, prepared.component)
        end
    end)

    it('gives OverlayWidget precedence over its Widget base', function()
        assert.equals('overlay', boundary:classify(TestOverlay).category)
        assert.equals('overlay', boundary:classify(TestOverlay()).category)
    end)

    it('rejects ambiguous factories and unsupported values actionably',
            function()
        assert.has_error(function() boundary:classify(function() end) end,
            'unsupported component input (function); expected a DFHack ' ..
            'defclass derived from widgets.Widget, overlay.OverlayWidget, ' ..
            'or gui.ZScreen, or an instance of one of those classes')
        assert.has_error(function() boundary:classify({}) end,
            'unsupported component input (table that is not a supported ' ..
            'DFHack component instance); expected a DFHack defclass derived ' ..
            'from widgets.Widget, overlay.OverlayWidget, or gui.ZScreen, or ' ..
            'an instance of one of those classes')
        local Other = make_class()
        assert.has_error(function() boundary:classify(Other) end,
            'unsupported component input (unsupported DFHack class); ' ..
            'DFHack class must derive from widgets.Widget, ' ..
            'overlay.OverlayWidget, or gui.ZScreen')
    end)

    it('normalizes common harness options and top-level attributes', function()
        local backing_viewscreen = {}
        local requested_viewport = {width=80, height=25}
        local prepared = boundary:prepare(PlainWidget, {
            viewport=requested_viewport,
            initial_pause=false,
            backing_viewscreen=backing_viewscreen,
            label='submit',
        })
        assert.same({width=80, height=25}, prepared.options.viewport)
        assert.is_false(prepared.options.initial_pause)
        assert.equals(backing_viewscreen,
            prepared.options.backing_viewscreen)
        assert.same({label='submit'}, prepared.options.attributes)
        assert.equals('submit', prepared.component.label)
        requested_viewport.width = 1
        assert.same({width=80, height=25}, prepared.options.viewport)

        local defaults = boundary:prepare(TestScreen)
        assert.is_true(defaults.options.initial_pause)
        assert.is_true(defaults.component.initial_pause)
        assert.same({width=128, height=64}, defaults.options.viewport)
        assert.same({}, defaults.options.attributes)

        local next_defaults = boundary:prepare(TestScreen)
        next_defaults.options.viewport.width = 1
        assert.same({width=128, height=64}, defaults.options.viewport)
    end)

    it('rejects component attributes for initialized instances', function()
        assert.has_error(function()
            boundary:prepare(PlainWidget(), {zebra=1, alpha=2})
        end, 'mount options cannot set component attributes for an ' ..
            'already-created instance: alpha, zebra')
    end)

    it('reports constructor and initialization errors as mount failures',
            function()
        local FailingConstructor = make_class(Widget)
        getmetatable(FailingConstructor).__call = function()
            error('constructor exploded')
        end
        local constructor_ok, constructor_message = pcall(
            boundary.prepare, boundary, FailingConstructor)
        assert.is_false(constructor_ok)
        assert.matches('DwarfSpec mount failed while constructing widget ' ..
            'component:', constructor_message, 1, true)
        assert.matches('constructor exploded', constructor_message, 1, true)

        local FailingWidget = make_class(Widget, function()
            error('initialization exploded')
        end)
        local ok, message = pcall(boundary.prepare, boundary, FailingWidget)
        assert.is_false(ok)
        assert.matches('DwarfSpec mount failed while constructing widget ' ..
            'component:', message, 1, true)
        assert.matches('initialization exploded', message, 1, true)
        assert.same({
            construction='mount_failure',
            initialization='mount_failure',
            first_render='mount_failure',
            infrastructure='host_error',
        }, component.FAILURE_OWNERSHIP)
    end)

    it('validates viewport and pause options', function()
        for _, case in ipairs({
            {viewport={width=0, height=25},
                message='mount option viewport.width must be a positive integer'},
            {viewport={width=1.5, height=25},
                message='mount option viewport.width must be a positive integer'},
            {viewport={width='80', height=25},
                message='mount option viewport.width must be a positive integer'},
            {viewport={width=80, height=-1},
                message='mount option viewport.height must be a positive integer'},
            {viewport={width=80, height=25.5},
                message='mount option viewport.height must be a positive integer'},
        }) do
            assert.has_error(function()
                boundary:prepare(PlainWidget, {viewport=case.viewport})
            end, case.message)
        end
        assert.has_error(function()
            boundary:prepare(PlainWidget, {initial_pause='yes'})
        end, 'mount option initial_pause must be a boolean')
    end)

    it('normalizes overlay-only test positioning', function()
        local prepared = boundary:prepare(TestOverlay(), {
            overlay_position={x=0, y=-5},
        })
        assert.same({x=1, y=-5}, prepared.options.overlay_position)
        assert.same({}, prepared.options.attributes)

        assert.has_error(function()
            boundary:prepare(PlainWidget, {
                overlay_position={x=1, y=2},
            })
        end, 'mount option overlay_position is only valid for ' ..
            'OverlayWidget components')
        assert.has_error(function()
            boundary:prepare(TestOverlay, {
                overlay_position={x=1.5, y=2},
            })
        end, 'mount option overlay_position.x must be an integer')
    end)

    it('reserves the initial mount and subject API names', function()
        assert.same({'mount', 'root', 'unmount', 'viewport'},
            component.PUBLIC_API.mount_context)
        assert.same({
            'click', 'hover', 'move_pointer', 'input', 'type',
            'inspect', 'text', 'raw',
        }, component.PUBLIC_API.subject)
    end)
end)
