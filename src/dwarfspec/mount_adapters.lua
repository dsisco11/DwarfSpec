-- DFHack component host adapters for the unified mount command.

local M = {}

---Creates the private screen class used for widget component mounts.
---@param gui_module table
---@param define_class function
---@return table
local function create_host_class(gui_module, define_class)
    ---@class dwarfspec.ComponentHostScreen: gui.ZScreen
    local HostScreen = define_class(nil, gui_module.ZScreen)
    HostScreen.ATTRS{
        component=DEFAULT_NIL,
        focus_path='dwarfspec/component-host',
        overlay_controller=DEFAULT_NIL,
        viewport=DEFAULT_NIL,
    }

    ---Adds the mounted component to its DwarfSpec-owned screen.
    function HostScreen:init()
        assert(self.component,
            'DwarfSpec component host requires a component')
        self:addviews{self.component}
    end

    ---Lays out hosted content against a fixed or live interface viewport.
    ---@param width integer
    ---@param height integer
    function HostScreen:onResize(width, height)
        if self.viewport then
            width = self.viewport.width
            height = self.viewport.height
        end
        HostScreen.super.onResize(self, width, height)
        if self.overlay_controller then
            self.overlay_controller:layout()
        end
    end

    ---Renders an overlay through its isolated painter contract.
    ---@param dc table
    function HostScreen:renderSubviews(dc)
        if self.overlay_controller then
            self.overlay_controller:render()
            return
        end
        HostScreen.super.renderSubviews(self, dc)
    end

    ---Runs overlay updates from the normal owned-screen idle callback.
    function HostScreen:onIdle()
        if HostScreen.super.onIdle then HostScreen.super.onIdle(self) end
        if self.overlay_controller then
            self.overlay_controller:update()
        end
    end

    ---Feeds overlay input with its active and visible lifecycle checks.
    ---@param keys table
    ---@return boolean
    function HostScreen:inputToSubviews(keys)
        if self.overlay_controller then
            return self.overlay_controller:input(keys)
        end
        return HostScreen.super.inputToSubviews(self, keys)
    end

    return HostScreen
end

---Returns whether a DFHack screen is currently active.
---@param screen table
---@return boolean
local function is_active(screen)
    if type(screen) ~= 'table' then return false end
    if type(screen.isActive) ~= 'function' then return false end
    local ok, active = pcall(screen.isActive, screen)
    return ok and not not active
end

---Registers reversible instrumentation and screen dismissal ownership.
---@param mount table
---@param screen table
---@param instrumentation table
---@param register_cleanup function
---@param enrich_failure function
local function prepare_screen(mount, screen, instrumentation,
        register_cleanup, enrich_failure)
    local restore = instrumentation.install(screen, mount.render_tracker,
        function(failure)
            return enrich_failure(mount, 'render', failure)
        end, function()
            if mount.refresh_views then mount.refresh_views() end
        end)
    register_cleanup(('restore component render interception %d')
        :format(mount.id), restore)
    register_cleanup(('dismiss component screen %d'):format(mount.id),
        function()
            if is_active(screen) then screen:dismiss() end
        end)
end

---Creates category adapters backed by live DFHack screens.
---@param options table
---@return function
function M.new(options)
    assert(type(options) == 'table',
        'mount adapters require dependency options')
    local gui_module = options.gui_module or require('gui')
    local instrumentation = assert(options.instrumentation,
        'mount adapters require render instrumentation')
    local enrich_failure = options.enrich_failure or
        function(_, _, failure) return tostring(failure) end
    local define_class = options.define_class or defclass
    local HostScreen = create_host_class(gui_module, define_class)
    local overlay_mount_module = options.overlay_mount_module or
        require('dwarfspec.overlay_mount')
    local overlay_factory = options.overlay_factory or
        overlay_mount_module.new({
            gui_module=gui_module,
            get_backing_viewscreen=options.get_backing_viewscreen,
            get_rects=options.get_overlay_rects,
            get_value=options.get_value,
            now_ms=options.now_ms,
            random=options.random,
        })

    local host_adapter = {}

    ---Shows one widget component in an instrumented DwarfSpec host screen.
    ---@param mount table
    ---@param prepared table
    ---@param register_cleanup function
    ---@return table
    function host_adapter:mount(mount, prepared, register_cleanup)
        local screen = HostScreen{
            component=prepared.component,
            initial_pause=prepared.options.initial_pause,
            viewport=prepared.options.viewport,
        }
        prepare_screen(mount, screen, instrumentation, register_cleanup,
            enrich_failure)
        screen:show(prepared.options.backing_viewscreen)
        return {root=prepared.component, host_screen=screen}
    end

    ---Dismisses a widget host if scoped cleanup has not already done so.
    ---@param mount table
    function host_adapter:unmount(mount)
        if is_active(mount.host_screen) then mount.host_screen:dismiss() end
    end

    ---@class dwarfspec.OverlayAdapter
    local overlay_adapter = {}

    ---Shows one overlay in the generic instrumented component host.
    ---@param mount table
    ---@param prepared table
    ---@param register_cleanup function
    ---@return table
    function overlay_adapter:mount(mount, prepared, register_cleanup)
        local controller = overlay_factory:create(
            mount, prepared.component, prepared.options)
        register_cleanup(('restore overlay component state %d')
            :format(mount.id), function() controller:restore() end)
        local screen = HostScreen{
            component=prepared.component,
            initial_pause=prepared.options.initial_pause,
            overlay_controller=controller,
            viewport=prepared.options.viewport,
        }
        prepare_screen(mount, screen, instrumentation, register_cleanup,
            enrich_failure)
        register_cleanup(('disable overlay component %d'):format(mount.id),
            function() controller:disable() end)
        controller:enable()
        screen:show(prepared.options.backing_viewscreen)
        return {root=prepared.component, host_screen=screen}
    end

    ---Dismisses an overlay host if scoped cleanup has not already done so.
    ---@param mount table
    function overlay_adapter:unmount(mount)
        if is_active(mount.host_screen) then mount.host_screen:dismiss() end
    end

    local screen_adapter = {}

    ---Shows one complete screen with reversible instance instrumentation.
    ---@param mount table
    ---@param prepared table
    ---@param register_cleanup function
    ---@return table
    function screen_adapter:mount(mount, prepared, register_cleanup)
        local screen = prepared.component
        prepare_screen(mount, screen, instrumentation, register_cleanup,
            enrich_failure)
        screen:show()
        return {root=screen, host_screen=screen}
    end

    ---Dismisses a complete screen if scoped cleanup has not already done so.
    ---@param mount table
    function screen_adapter:unmount(mount)
        if is_active(mount.host_screen) then mount.host_screen:dismiss() end
    end

    ---Returns the adapter for a supported component category.
    ---@param category string
    ---@return table
    return function(category)
        if category == 'widget' then return host_adapter end
        if category == 'overlay' then return overlay_adapter end
        if category == 'screen' then return screen_adapter end
        error('unsupported DwarfSpec component category: ' ..
            tostring(category), 2)
    end
end

return M
