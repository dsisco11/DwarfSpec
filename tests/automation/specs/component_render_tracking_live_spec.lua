-- Live render synchronization contracts for product-independent components.

local gui = require('gui')
local widgets = require('gui.widgets')
local overlay = require('plugins.overlay')

---@class tests.PlainMountWidget: widgets.Label
local PlainMountWidget = defclass(nil, widgets.Label)
PlainMountWidget.ATTRS{
    text='plain widget render',
}

---@class tests.PlainMountOverlay: overlay.OverlayWidget
local PlainMountOverlay = defclass(nil, overlay.OverlayWidget)
PlainMountOverlay.ATTRS{
    frame={w=24, h=1},
}

---@class tests.PlainMountScreen: gui.ZScreen
local PlainMountScreen = defclass(nil, gui.ZScreen)
PlainMountScreen.ATTRS{
    focus_path='dwarfspec/plain-mount-screen',
}

---@class tests.FailingMountWidget: widgets.Widget
local FailingMountWidget = defclass(nil, widgets.Widget)

---Raises the component's original render failure.
---@param dc gui.Painter
function FailingMountWidget:onRenderBody(dc)
    error('deliberate component render failure', 0)
end

describe('automatic component render tracking', function()
    it('mounts a plain widget class through a completed live render', function()
        local subject = ds.mount(PlainMountWidget)

        assert.equals(PlainMountWidget, getmetatable(subject:raw()))
        assert.is_nil(subject:raw().render_generation)
        ds.hover(subject)
        ds.click(subject)
        ds.input('CUSTOM_A')
        ds.type('A')
        ds.resize(40, 20)
        ds.unmount()
    end)

    it('mounts an existing overlay instance through a completed live render',
            function()
        local instance = PlainMountOverlay{}
        local subject = ds.mount(instance)

        assert.equals(instance, subject:raw())
        assert.is_nil(instance.render_generation)
        ds.unmount()
    end)

    it('mounts a complete screen class without class cooperation', function()
        local subject = ds.mount(PlainMountScreen)
        local screen = subject:raw()

        assert.equals(PlainMountScreen, getmetatable(screen))
        assert.is_nil(screen.render_generation)
        assert.is_nil(rawget(PlainMountScreen, 'onRender'))
        ds.unmount()
        assert.is_nil(rawget(screen, 'onRender'))
    end)

    it('retains the original render failure with bounded mount diagnostics',
            function()
        local ok, message = pcall(ds.mount, FailingMountWidget)
        local run = assert(dfhack.dwarfspec.active_run)

        assert.is_false(ok)
        assert.matches('deliberate component render failure', message,
            1, true)
        assert.matches('DwarfSpec mount failure:', message, 1, true)
        assert.matches('component_tree=', message, 1, true)
        assert.matches('screen_capture=', message, 1, true)
        assert.equals('render', run.last_mount_diagnostics.operation)
        assert.equals('widget', run.last_mount_diagnostics.category)
        assert.is_true(run.last_mount_diagnostics.tree.capture_bounds
            .node_count <= 128)
        assert.equals(128, run.last_mount_diagnostics.tree.capture_bounds
            .max_nodes)
        assert.equals(8, run.last_mount_diagnostics.tree.capture_bounds
            .max_depth)
        assert.is_true(run.last_mount_diagnostics.screen.width <= 16)
        assert.is_true(run.last_mount_diagnostics.screen.height <= 8)
        local lifecycle = run.mount_cleanup_probe()
        assert.is_nil(lifecycle.current_mount_id)
        assert.equals(0, lifecycle.active_screen_count)
        assert.equals(0, lifecycle.subject_count)
        assert.has_error(function() ds.root() end,
            'DwarfSpec root requires a mounted component; call ' ..
                'ds.mount(component, options) first')
    end)
end)
