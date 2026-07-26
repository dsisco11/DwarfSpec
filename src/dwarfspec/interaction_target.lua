-- Mount-specific interaction routing for owned and borrowed screens.

local M = {}

local EResolutionStage =
    require('dwarfspec.native_resolution_stages')
local identity_labels = require('dwarfspec.identity_labels')

local DIAGNOSTIC_LABEL_LIMIT = 256

---Returns a bounded scalar diagnostic without dumping compound values.
---@param value any
---@return string
local function bounded_diagnostic(value)
    if type(value) == 'table' or type(value) == 'userdata' then
        return identity_labels.of(value)
    end
    local ok, label = pcall(tostring, value)
    if not ok then return '<unavailable>' end
    if #label <= DIAGNOSTIC_LABEL_LIMIT then return label end
    return label:sub(1, DIAGNOSTIC_LABEL_LIMIT - 3) .. '...'
end

---@class dwarfspec.OwnedScreenInteractionTarget
---@field _screen table|nil
---@field _is_active fun(screen: table): boolean
---@field _resolve_native_screen fun(screen: table): any
---@field _cleaned boolean
local OwnedScreenInteractionTarget = {}
OwnedScreenInteractionTarget.__index = OwnedScreenInteractionTarget

---@class dwarfspec.BorrowedNativeInteractionTarget
---@field _screen any|nil
---@field _get_current_viewscreen function|nil
---@field _invalidate_screen function|nil
---@field _cleaned boolean
local BorrowedNativeInteractionTarget = {}
BorrowedNativeInteractionTarget.__index = BorrowedNativeInteractionTarget

---Returns the owned screen while it remains available and active.
---@param operation string
---@return table
function OwnedScreenInteractionTarget:assert_current(operation)
    assert(type(operation) == 'string' and operation ~= '',
        'interaction operation must be a nonempty string')
    assert(not self._cleaned and self._screen,
        operation .. ' screen is no longer available')
    assert(self._is_active(self._screen),
        operation .. ' screen is not currently active')
    return self._screen
end

---Returns the active native screen belonging to the owned component.
---@param operation string
---@return any
function OwnedScreenInteractionTarget:native_screen(operation)
    local screen = self:assert_current(operation)
    return self._resolve_native_screen(screen)
end

---Returns the owned native screen that should receive simulated input.
---@param operation string
---@return any
function OwnedScreenInteractionTarget:input_screen(operation)
    local screen = self:native_screen(operation)
    assert(screen ~= nil,
        operation .. ' input screen is no longer available')
    return screen
end

---Invalidates the owned screen after validating its current lifecycle.
---@return any
function OwnedScreenInteractionTarget:invalidate()
    local screen = self:assert_current('redraw')
    assert(type(screen.invalidate) == 'function',
        'mounted screen does not support redraw')
    return screen:invalidate()
end

---Releases this non-owning interaction reference without dismissing its screen.
---@return boolean
function OwnedScreenInteractionTarget:cleanup()
    if self._cleaned then return false end
    self._cleaned = true
    self._screen = nil
    return true
end

---Creates an interaction target for one DwarfSpec-owned screen.
---@param screen table
---@param options table
---@return dwarfspec.OwnedScreenInteractionTarget
function M.new_owned_screen(screen, options)
    assert(type(screen) == 'table',
        'owned-screen interaction target requires a screen table')
    assert(type(options) == 'table',
        'owned-screen interaction target requires dependency options')
    assert(type(options.is_active) == 'function',
        'owned-screen interaction target requires active-state access')
    assert(type(options.resolve_native_screen) == 'function',
        'owned-screen interaction target requires native-screen resolution')
    return setmetatable({
        _screen=screen,
        _is_active=options.is_active,
        _resolve_native_screen=options.resolve_native_screen,
        _cleaned=false,
    }, OwnedScreenInteractionTarget)
end

---Returns the pinned native viewscreen while the borrowed mount remains live.
---@param operation string
---@param diagnostics table|nil Accepted for uniform mount validation.
---@return any
function BorrowedNativeInteractionTarget:assert_current(
        operation, diagnostics)
    assert(type(operation) == 'string' and operation ~= '',
        'interaction operation must be a nonempty string')
    assert(not self._cleaned and self._screen and
        self._get_current_viewscreen,
        ('stage=%s %s native screen is no longer available'):format(
            EResolutionStage.RETAINED_SUBJECT_REACQUISITION,
            operation))
    return self._screen
end

---Returns the pinned base DF viewscreen for non-input operations.
---@param operation string
---@return any
function BorrowedNativeInteractionTarget:native_screen(operation)
    return self:assert_current(operation)
end

---Returns the viewscreen that should receive simulated native input now.
---@param operation string
---@return any
function BorrowedNativeInteractionTarget:input_screen(operation)
    self:assert_current(operation)
    local ok, current = pcall(self._get_current_viewscreen)
    assert(ok,
        ('DwarfSpec %s could not query the current input viewscreen: %s')
            :format(operation, bounded_diagnostic(current)))
    assert(current ~= nil,
        ('DwarfSpec %s requires a current input viewscreen')
            :format(operation))
    return current
end

---Invalidates native rendering while preserving the borrowed screen.
---@return any
function BorrowedNativeInteractionTarget:invalidate()
    self:assert_current('redraw')
    assert(self._invalidate_screen,
        'native screen invalidation is no longer available')
    return self._invalidate_screen()
end

---Releases borrowed callbacks and identity without mutating the native screen.
---@return boolean
function BorrowedNativeInteractionTarget:cleanup()
    if self._cleaned then return false end
    self._cleaned = true
    self._screen = nil
    self._get_current_viewscreen = nil
    self._invalidate_screen = nil
    return true
end

---Creates a non-owning interaction target for one pinned native viewscreen.
---@param screen any
---@param options table
---@return dwarfspec.BorrowedNativeInteractionTarget
function M.new_borrowed_native(screen, options)
    assert(screen ~= nil,
        'borrowed native interaction target requires a viewscreen')
    assert(type(options) == 'table',
        'borrowed native interaction target requires dependency options')
    assert(type(options.get_current_viewscreen) == 'function',
        'borrowed native interaction target requires current-screen access')
    assert(type(options.invalidate_screen) == 'function',
        'borrowed native interaction target requires screen invalidation')
    return setmetatable({
        _screen=screen,
        _get_current_viewscreen=options.get_current_viewscreen,
        _invalidate_screen=options.invalidate_screen,
        _cleaned=false,
    }, BorrowedNativeInteractionTarget)
end

return M
