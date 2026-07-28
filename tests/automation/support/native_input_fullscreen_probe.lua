--@ module=true

-- Registered trigger overlay that owns a test-only fullscreen input screen.

local gui = require('gui')
local overlay = require('plugins.overlay')
local widgets = require('gui.widgets')

local MOUSE_KEYS = {
    _MOUSE_L=true,
    _MOUSE_L_DOWN=true,
    _MOUSE_R=true,
    _MOUSE_R_DOWN=true,
    _MOUSE_M=true,
    _MOUSE_M_DOWN=true,
    CONTEXT_SCROLL_UP=true,
    CONTEXT_SCROLL_DOWN=true,
    CONTEXT_SCROLL_PAGEUP=true,
    CONTEXT_SCROLL_PAGEDOWN=true,
}

---Returns the active DwarfSpec run while live automation owns the fixture.
---@return table|nil
local function active_run()
    local registry = dfhack.dwarfspec
    local run_id = registry and registry.active_run_id
    return run_id and registry.runs[run_id] or nil
end

---Marks one exact fixture-owned screen for dismissal.
---@param screen tests.NativeInputFullscreenScreen
---@return boolean
local function dismiss_owned_screen(screen)
    local native = screen._native
    if not native then return true end
    if screen:isActive() then screen:dismiss() end
    if screen:isActive() and screen._native == native then
        native.breakdown_level = df.interface_breakdown_types.STOPSCREEN
    end
    return not screen:isActive()
end

---Registers cleanup for one exact fixture-owned screen.
---@param screen tests.NativeInputFullscreenScreen
local function register_screen_cleanup(screen)
    local run = assert(active_run(),
        'native input fullscreen cleanup requires an active DwarfSpec run')
    local cleanup_module = assert(run.cleanup_module,
        'native input fullscreen cleanup module is unavailable')
    local cleanup_registry = assert(run.cleanup_registry,
        'native input fullscreen cleanup registry is unavailable')
    local native = assert(screen._native,
        'native input fullscreen screen has no native backing')
    screen.cleanup_module = cleanup_module
    screen.cleanup_registry = cleanup_registry
    screen.cleanup_entry = cleanup_module.push(cleanup_registry,
        'dismiss native input fullscreen probe', function()
            if screen._native ~= native then return end
            assert(dismiss_owned_screen(screen),
                'native input fullscreen probe resisted dismissal')
        end)
end

---Records one scalar fixture event without retaining a UI object.
---@param name string
local function record(name)
    local run = active_run()
    if not run then return end
    run.native_input_routing_events =
        run.native_input_routing_events or {}
    local events = run.native_input_routing_events
    events[name] = (events[name] or 0) + 1
end

---Returns sorted names for the active keys in one DFHack input table.
---@param keys table
---@return string[]
local function active_key_names(keys)
    local names = {}
    for name, active in pairs(keys) do
        if active then table.insert(names, name) end
    end
    table.sort(names)
    return names
end

---Returns whether one input table represents a mouse action.
---@param keys table
---@return boolean
local function is_mouse_input(keys)
    for name in pairs(MOUSE_KEYS) do
        if keys[name] then return true end
    end
    return false
end

---@class tests.NativeInputFullscreenScreen: gui.ZScreen
---@field probe tests.NativeInputFullscreenOverlay
---@field input_count integer
---@field keyboard_count integer
---@field mouse_count integer
---@field render_count integer
---@field last_keys string[]
---@field cleanup_module table|nil
---@field cleanup_registry table|nil
---@field cleanup_entry table|nil
local NativeInputFullscreenScreen = defclass(nil, gui.ZScreen)
NativeInputFullscreenScreen.ATTRS{
    focus_path='dwarfspec/native-input-fullscreen',
    initial_pause=false,
    pass_mouse_clicks=false,
    pass_movement_keys=false,
    probe=DEFAULT_NIL,
}

---Builds the rendered pointer target and initializes observation counters.
function NativeInputFullscreenScreen:init()
    assert(self.probe,
        'native input fullscreen screen requires its registered probe')
    self.input_count = 0
    self.keyboard_count = 0
    self.mouse_count = 0
    self.render_count = 0
    self.last_keys = {}
    self:addviews{
        widgets.Label{
            view_id='target',
            frame={l=2, t=2, w=32, h=1},
            text='DwarfSpec fullscreen input target',
        },
    }
end

---Records normal screen input and either consumes it or sends it to its parent.
---@param keys table
---@return boolean
function NativeInputFullscreenScreen:onInput(keys)
    self.input_count = self.input_count + 1
    self.last_keys = active_key_names(keys)
    if is_mouse_input(keys) then
        self.mouse_count = self.mouse_count + 1
        record('mouse_input')
    else
        self.keyboard_count = self.keyboard_count + 1
        record('keyboard_input')
    end
    record('input')
    if not self.probe.consume_input then
        self:sendInputToParent(keys)
        record('passed_to_parent')
    else
        record('consumed')
    end
    return true
end

---Records rendering before delegating to the ordinary fullscreen screen path.
---@param dc gui.Painter
function NativeInputFullscreenScreen:render(dc)
    self.render_count = self.render_count + 1
    record('render')
    NativeInputFullscreenScreen.super.render(self, dc)
end

---Releases the owning probe's active-screen reference after dismissal.
function NativeInputFullscreenScreen:onDismiss()
    if self.probe.active_screen == self then
        self.probe.active_screen = nil
    end
    self.probe.last_screen = self
    record('dismissed')
end

---Releases cleanup ownership after DFHack destroys the native backing screen.
function NativeInputFullscreenScreen:onDestroy()
    if self.probe.active_screen == self then
        self.probe.active_screen = nil
    end
    if self.cleanup_entry then
        self.cleanup_module.release(
            self.cleanup_registry, self.cleanup_entry)
    end
    self.cleanup_module = nil
    self.cleanup_registry = nil
    self.cleanup_entry = nil
end

---@class tests.NativeInputFullscreenOverlay: plugins.overlay.OverlayWidget
---@field consume_input boolean
---@field active_screen tests.NativeInputFullscreenScreen|nil
---@field last_screen tests.NativeInputFullscreenScreen|nil
local NativeInputFullscreenOverlay = defclass(
    nil, overlay.OverlayWidget)
NativeInputFullscreenOverlay.ATTRS{
    desc='DwarfSpec fullscreen native-input routing probe',
    default_enabled=false,
    default_pos={x=1, y=1},
    viewscreens='dwarfmode',
    frame={w=1, h=1},
}

---Initializes deterministic input and screen ownership state.
function NativeInputFullscreenOverlay:init()
    self.consume_input = true
    self.active_screen = nil
    self.last_screen = nil
    self.overlay_onenable = function()
        record('enabled')
    end
    self.overlay_ondisable = function()
        self:dismiss_screen()
        record('disabled')
    end
end

---Shows and returns a new fullscreen screen through overlay trigger handling.
---@return tests.NativeInputFullscreenScreen
function NativeInputFullscreenOverlay:overlay_trigger()
    assert(not self.active_screen or not self.active_screen:isActive(),
        'native input fullscreen probe is already active')
    local screen = NativeInputFullscreenScreen{probe=self}:show()
    local cleanup_ok, cleanup_error =
        xpcall(register_screen_cleanup, debug.traceback, screen)
    if not cleanup_ok then
        dismiss_owned_screen(screen)
        error(cleanup_error, 0)
    end
    self.active_screen = screen
    self.last_screen = screen
    record('triggered')
    return screen
end

---Selects whether the active fullscreen screen consumes subsequent input.
---@param consume boolean
function NativeInputFullscreenOverlay:set_consume(consume)
    assert(type(consume) == 'boolean',
        'fullscreen input consumption must be boolean')
    self.consume_input = consume
end

---Dismisses the active fullscreen screen without changing registration state.
---@return boolean
function NativeInputFullscreenOverlay:dismiss_screen()
    local screen = self.active_screen
    if not screen or not screen:isActive() then return false end
    return dismiss_owned_screen(screen)
end

OVERLAY_WIDGETS = {
    fullscreen_input=NativeInputFullscreenOverlay,
}
