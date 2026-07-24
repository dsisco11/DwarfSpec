-- Read-only adaptation of one exact externally owned DFHack overlay widget.

local ESubjectSource = require('dwarfspec.subject_sources')
local lua_view_adapter = require('dwarfspec.lua_view_adapter')

local M = {}

---@class dwarfspec.OverlayRegistryAdapter: dwarfspec.SubjectAdapter
---@field _overlay_name string|nil
---@field _root table|nil
---@field _get_state function|nil
---@field _is_lua_view function|nil
---@field _delegate dwarfspec.LuaViewAdapter|nil
---@field _cleaned boolean
local OverlayRegistryAdapter = {}
OverlayRegistryAdapter.__index = OverlayRegistryAdapter

---Returns whether a value has the minimum stable Lua-view shape.
---@param value any
---@return boolean
local function default_is_lua_view(value)
    return type(value) == 'table' and type(value.subviews) == 'table'
end

---Reads the registry and returns its exact named widget.
---@param get_state function
---@param overlay_name string
---@param is_lua_view function
---@param stale boolean
---@return table
local function read_widget(get_state, overlay_name, is_lua_view, stale)
    local ok, state = pcall(get_state)
    local prefix = stale and 'DwarfSpec stale overlay subject' or
        'DwarfSpec overlay subject selection'
    assert(ok, ('%s failed to read registry name=%q: %s')
        :format(prefix, overlay_name, tostring(state)))
    assert(type(state) == 'table' and type(state.db) == 'table' and
        type(state.config) == 'table',
        ('%s received invalid registry state for name=%q')
            :format(prefix, overlay_name))
    local entry = state.db[overlay_name]
    assert(type(entry) == 'table',
        ('%s could not find exact registry name=%q')
            :format(prefix, overlay_name))
    local config = state.config[overlay_name]
    assert(type(config) == 'table' and config.enabled == true,
        ('%s requires enabled registry name=%q')
            :format(prefix, overlay_name))
    assert(is_lua_view(entry.widget),
        ('%s requires registry name=%q to contain a valid Lua view')
            :format(prefix, overlay_name))
    return entry.widget
end

---Returns the pinned root after revalidating registry name and identity.
---@param self dwarfspec.OverlayRegistryAdapter
---@return table
local function require_current(self)
    assert(not self._cleaned and self._root and self._get_state and
        self._is_lua_view and self._delegate,
        'DwarfSpec overlay subject source is no longer available')
    local current = read_widget(
        self._get_state, self._overlay_name, self._is_lua_view, true)
    assert(current == self._root,
        ('DwarfSpec stale overlay subject registry name=%q was replaced; ' ..
            'select the overlay source again'):format(self._overlay_name))
    return self._root
end

---Returns whether the exact pinned registry mapping remains current.
---@return boolean
function OverlayRegistryAdapter:is_current()
    local ok = pcall(require_current, self)
    return ok
end

---Returns the exact pinned overlay widget.
---@return table
function OverlayRegistryAdapter:root()
    return require_current(self)
end

---Resolves a strict Lua-view path beneath the pinned overlay widget.
---@param path_segments string[]
---@return table|nil, table|nil
function OverlayRegistryAdapter:resolve(path_segments)
    require_current(self)
    return self._delegate:resolve(path_segments)
end

---Returns stable Lua object identity after registry revalidation.
---@param raw table
---@return table
function OverlayRegistryAdapter:identity(raw)
    require_current(self)
    return self._delegate:identity(raw)
end

---Returns whether a Lua view remains beneath the pinned overlay root.
---@param raw any
---@return boolean
function OverlayRegistryAdapter:contains(raw)
    require_current(self)
    return self._delegate:contains(raw)
end

---Returns ordered Lua-view children after registry revalidation.
---@param raw table
---@return table[]
function OverlayRegistryAdapter:children(raw)
    require_current(self)
    return self._delegate:children(raw)
end

---Returns one Lua-view identifier after registry revalidation.
---@param raw table
---@return string|nil
function OverlayRegistryAdapter:name(raw)
    require_current(self)
    return self._delegate:name(raw)
end

---Returns one Lua-view class label after registry revalidation.
---@param raw table
---@return string
function OverlayRegistryAdapter:native_type(raw)
    require_current(self)
    return self._delegate:native_type(raw)
end

---Returns live Lua-view bounds after registry revalidation.
---@param raw table
---@return table|nil
function OverlayRegistryAdapter:bounds(raw)
    require_current(self)
    return self._delegate:bounds(raw)
end

---Returns evaluated Lua-view visibility after registry revalidation.
---@param raw table
---@return boolean
function OverlayRegistryAdapter:visible(raw)
    require_current(self)
    return self._delegate:visible(raw)
end

---Returns evaluated Lua-view activity after registry revalidation.
---@param raw table
---@return boolean
function OverlayRegistryAdapter:active(raw)
    require_current(self)
    return self._delegate:active(raw)
end

---Returns Lua-view focus state after registry revalidation.
---@param raw table
---@return boolean
function OverlayRegistryAdapter:focused(raw)
    require_current(self)
    return self._delegate:focused(raw)
end

---Returns Lua-view text after registry revalidation.
---@param raw table
---@return string|nil
function OverlayRegistryAdapter:text(raw)
    require_current(self)
    return self._delegate:text(raw)
end

---Returns Lua-view tooltip text after registry revalidation.
---@param raw table
---@return string|nil
function OverlayRegistryAdapter:tooltip(raw)
    require_current(self)
    return self._delegate:tooltip(raw)
end

---Returns documented Lua-view optional fields after registry revalidation.
---@param raw table
---@return table
function OverlayRegistryAdapter:optional_fields(raw)
    require_current(self)
    return self._delegate:optional_fields(raw)
end

---Returns a stable Lua-view inspection after registry revalidation.
---@param raw table
---@return table
function OverlayRegistryAdapter:inspect(raw)
    require_current(self)
    return self._delegate:inspect(raw)
end

---Releases retained references without mutating the overlay registry or widget.
---@return boolean
function OverlayRegistryAdapter:cleanup()
    if self._cleaned then return false end
    self._cleaned = true
    if self._delegate then self._delegate:cleanup() end
    self._overlay_name = nil
    self._root = nil
    self._get_state = nil
    self._is_lua_view = nil
    self._delegate = nil
    return true
end

---Creates a read-only adapter for one exact enabled overlay registry entry.
---@param overlay_name string
---@param options table
---@return dwarfspec.OverlayRegistryAdapter
function M.new(overlay_name, options)
    assert(type(overlay_name) == 'string' and overlay_name ~= '',
        'overlay registry adapter requires an exact nonempty name')
    assert(type(options) == 'table' and
        type(options.get_state) == 'function',
        'overlay registry adapter requires get_state access')
    local is_lua_view = options.is_lua_view or default_is_lua_view
    assert(type(is_lua_view) == 'function',
        'overlay registry Lua-view validation must be callable')
    local root = read_widget(
        options.get_state, overlay_name, is_lua_view, false)
    return setmetatable({
        _overlay_name=overlay_name,
        _root=root,
        _get_state=options.get_state,
        _is_lua_view=is_lua_view,
        _delegate=lua_view_adapter.new(root),
        _cleaned=false,
    }, OverlayRegistryAdapter)
end

---Creates an explicit overlay subject source without taking lifecycle ownership.
---@param overlay_name string
---@param options table
---@return dwarfspec.SubjectSource
function M.new_source(overlay_name, options)
    return {
        kind=ESubjectSource.OVERLAY,
        overlay=overlay_name,
        adapter=M.new(overlay_name, options),
    }
end

return M
