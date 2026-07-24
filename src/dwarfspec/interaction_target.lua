-- Interaction routing for DwarfSpec-owned component screens.

local M = {}

---@class dwarfspec.InteractionTarget
---@field _screen table|nil
---@field _is_active fun(screen: table): boolean
---@field _resolve_native_screen fun(screen: table): any
---@field _cleaned boolean
local InteractionTarget = {}
InteractionTarget.__index = InteractionTarget

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
function InteractionTarget:assert_current(operation)
    assert(type(operation) == 'string' and operation ~= '',
        'interaction operation must be a nonempty string')
    assert(not self._cleaned and self._screen,
        operation .. ' screen is no longer available')
    assert(self._is_active(self._screen),
        operation .. ' screen is not currently active')
    return self._screen
end

---Returns the native viewscreen that should receive normal DFHack input.
---@param operation string
---@return any
function InteractionTarget:native_screen(operation)
    local screen = self:assert_current(operation)
    return self._resolve_native_screen(screen)
end

---Invalidates the owned screen after validating its current lifecycle.
---@return any
function InteractionTarget:invalidate()
    local screen = self:assert_current('redraw')
    assert(type(screen.invalidate) == 'function',
        'mounted screen does not support redraw')
    return screen:invalidate()
end

---Releases this non-owning interaction reference without dismissing its screen.
---@return boolean
function InteractionTarget:cleanup()
    if self._cleaned then return false end
    self._cleaned = true
    self._screen = nil
    return true
end

---Creates an interaction target for one DwarfSpec-owned screen.
---@param screen table
---@param options table
---@return dwarfspec.InteractionTarget
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
    }, InteractionTarget)
end

---Returns the pinned native viewscreen only while it remains exactly current.
---@param operation string
---@return any
function BorrowedNativeInteractionTarget:assert_current(operation)
    assert(type(operation) == 'string' and operation ~= '',
        'interaction operation must be a nonempty string')
    assert(not self._cleaned and self._screen and
        self._get_current_viewscreen,
        operation .. ' native screen is no longer available')
    local ok, current = pcall(self._get_current_viewscreen)
    assert(ok,
        ('DwarfSpec %s could not query the current viewscreen: %s')
            :format(operation, tostring(current)))
    assert(current == self._screen,
        ('DwarfSpec %s rejected stale native-screen mount; pinned ' ..
        'viewscreen is no longer current'):format(operation))
    return self._screen
end

---Returns the pinned viewscreen for normal DFHack input dispatch.
---@param operation string
---@return any
function BorrowedNativeInteractionTarget:native_screen(operation)
    return self:assert_current(operation)
end

---Invalidates the native screen globally after validating its identity.
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
