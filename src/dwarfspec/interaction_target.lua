-- Interaction routing for DwarfSpec-owned component screens.

local M = {}

---@class dwarfspec.InteractionTarget
---@field _screen table|nil
---@field _is_active fun(screen: table): boolean
---@field _resolve_native_screen fun(screen: table): any
---@field _cleaned boolean
local InteractionTarget = {}
InteractionTarget.__index = InteractionTarget

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

return M
