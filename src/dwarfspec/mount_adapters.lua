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
    }

    ---Adds the mounted component to its DwarfSpec-owned screen.
    function HostScreen:init()
        assert(self.component,
            'DwarfSpec component host requires a component')
        self:addviews{self.component}
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

    local host_adapter = {}

    ---Shows one widget component in an instrumented DwarfSpec host screen.
    ---@param mount table
    ---@param prepared table
    ---@param register_cleanup function
    ---@return table
    function host_adapter:mount(mount, prepared, register_cleanup)
        local screen = HostScreen{component=prepared.component}
        prepare_screen(mount, screen, instrumentation, register_cleanup,
            enrich_failure)
        screen:show()
        return {root=prepared.component, host_screen=screen}
    end

    ---Dismisses a widget host if scoped cleanup has not already done so.
    ---@param mount table
    function host_adapter:unmount(mount)
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
        if category == 'widget' or category == 'overlay' then
            return host_adapter
        end
        if category == 'screen' then return screen_adapter end
        error('unsupported DwarfSpec component category: ' ..
            tostring(category), 2)
    end
end

return M
