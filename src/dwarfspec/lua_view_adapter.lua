-- Subject adaptation for DFHack Lua gui.View component trees.

local M = {}

---@class dwarfspec.SubjectAdapter
---@field root fun(self: dwarfspec.SubjectAdapter): any
---@field resolve fun(self: dwarfspec.SubjectAdapter, path_segments: string[]): any, table|nil
---@field identity fun(self: dwarfspec.SubjectAdapter, raw: any): any
---@field contains fun(self: dwarfspec.SubjectAdapter, raw: any): boolean
---@field children fun(self: dwarfspec.SubjectAdapter, raw: any): table[]
---@field name fun(self: dwarfspec.SubjectAdapter, raw: any): string|nil
---@field native_type fun(self: dwarfspec.SubjectAdapter, raw: any): string
---@field bounds fun(self: dwarfspec.SubjectAdapter, raw: any): table|nil
---@field visible fun(self: dwarfspec.SubjectAdapter, raw: any): boolean
---@field active fun(self: dwarfspec.SubjectAdapter, raw: any): boolean
---@field focused fun(self: dwarfspec.SubjectAdapter, raw: any): boolean
---@field text fun(self: dwarfspec.SubjectAdapter, raw: any): string|nil
---@field tooltip fun(self: dwarfspec.SubjectAdapter, raw: any): string|nil
---@field optional_fields fun(self: dwarfspec.SubjectAdapter, raw: any): table
---@field inspect fun(self: dwarfspec.SubjectAdapter, raw: any): table
---@field cleanup fun(self: dwarfspec.SubjectAdapter): boolean

---@class dwarfspec.SubjectSource
---@field kind? DwarfSpecESubjectSource
---@field adapter dwarfspec.SubjectAdapter

---@class dwarfspec.LuaViewAdapter: dwarfspec.SubjectAdapter
---@field _root table|nil
---@field _cleaned boolean
local LuaViewAdapter = {}
LuaViewAdapter.__index = LuaViewAdapter

---Returns a scalar value or evaluates one lazy Lua-view property.
---@param value any
---@return any
local function get_value(value)
    if type(value) ~= 'function' then return value end
    local ok, result = pcall(value)
    if not ok then return '<unavailable>' end
    return result
end

---Returns a stable class label for one Lua view.
---@param view table
---@return string
local function class_name(view)
    local type_value = view and view._type
    if type(type_value) == 'string' then return type_value end
    if type(type_value) == 'table' then
        return type_value._name or type_value.name or '<view>'
    end
    return type(view)
end

---Copies one live Lua-view rectangle into plain coordinates.
---@param rect table|nil
---@return table|nil
local function copy_rect(rect)
    if not rect then return nil end
    return {
        x1=rect.x1,
        y1=rect.y1,
        x2=rect.x2,
        y2=rect.y2,
        clip_x1=rect.clip_x1,
        clip_y1=rect.clip_y1,
        clip_x2=rect.clip_x2,
        clip_y2=rect.clip_y2,
    }
end

---Returns a stable text representation of one Lua-view property.
---@param value any
---@return string|nil
local function text_value(value)
    if value == nil then return nil end
    if type(value) == 'string' then return value end
    if type(value) == 'number' or type(value) == 'boolean' then
        return tostring(value)
    end
    return '<' .. type(value) .. '>'
end

---Returns the exact root Lua view owned by this source.
---@return table
function LuaViewAdapter:root()
    assert(not self._cleaned and self._root,
        'Lua view subject source is no longer available')
    return self._root
end

---Resolves exact direct-child view IDs from the adapter root.
---@param path_segments string[]
---@return table|nil, table|nil
function LuaViewAdapter:resolve(path_segments)
    assert(type(path_segments) == 'table',
        'Lua view path segments must be a table')
    local view = self:root()
    for index, segment in ipairs(path_segments) do
        local selected = nil
        for _, child in ipairs(self:children(view)) do
            if self:name(child) == segment then
                assert(selected == nil,
                    ('Lua view tree has multiple direct children named %q')
                        :format(segment))
                selected = child
            end
        end
        if not selected then
            return nil, {
                index=index,
                segment=segment,
                parent=view,
            }
        end
        view = selected
    end
    return view
end

---Returns the stable Lua object identity used by retained subjects.
---@param raw table
---@return table
function LuaViewAdapter:identity(raw)
    assert(type(raw) == 'table', 'Lua view identity requires a table')
    return raw
end

---Returns whether an exact Lua view remains beneath the current root.
---@param raw any
---@return boolean
function LuaViewAdapter:contains(raw)
    if type(raw) ~= 'table' or self._cleaned or not self._root then
        return false
    end
    local visited = setmetatable({}, {__mode='k'})

    ---Searches one Lua-view subtree without revisiting shared nodes.
    ---@param view table
    ---@return boolean
    local function visit(view)
        if view == raw then return true end
        if visited[view] then return false end
        visited[view] = true
        for _, child in ipairs(self:children(view)) do
            if visit(child) then return true end
        end
        return false
    end

    return visit(self._root)
end

---Returns the ordered direct Lua-view children.
---@param raw table
---@return table[]
function LuaViewAdapter:children(raw)
    assert(type(raw) == 'table', 'Lua view children require a table')
    return raw.subviews or {}
end

---Returns the component control identifier for one Lua view.
---@param raw table
---@return string|nil
function LuaViewAdapter:name(raw)
    assert(type(raw) == 'table', 'Lua view name requires a table')
    return raw.view_id
end

---Returns the stable class label for one Lua view.
---@param raw table
---@return string
function LuaViewAdapter:native_type(raw)
    assert(type(raw) == 'table', 'Lua view type requires a table')
    return class_name(raw)
end

---Returns the live body rectangle used for pointer interaction.
---@param raw table
---@return table|nil
function LuaViewAdapter:bounds(raw)
    assert(type(raw) == 'table', 'Lua view bounds require a table')
    return raw.frame_body
end

---Returns the evaluated direct visibility of one Lua view.
---@param raw table
---@return boolean
function LuaViewAdapter:visible(raw)
    assert(type(raw) == 'table', 'Lua view visibility requires a table')
    return not not get_value(raw.visible)
end

---Returns the evaluated direct activity of one Lua view.
---@param raw table
---@return boolean
function LuaViewAdapter:active(raw)
    assert(type(raw) == 'table', 'Lua view activity requires a table')
    return not not get_value(raw.active)
end

---Returns whether one Lua view currently owns keyboard focus.
---@param raw table
---@return boolean
function LuaViewAdapter:focused(raw)
    assert(type(raw) == 'table', 'Lua view focus requires a table')
    local focused = not not raw.focus
    if type(raw.hasFocus) == 'function' then
        local ok, value = pcall(raw.hasFocus, raw)
        focused = ok and not not value
    end
    return focused
end

---Returns stable text for one Lua view when available.
---@param raw table
---@return string|nil
function LuaViewAdapter:text(raw)
    assert(type(raw) == 'table', 'Lua view text requires a table')
    return text_value(raw.text)
end

---Returns stable tooltip text for one Lua view when available.
---@param raw table
---@return string|nil
function LuaViewAdapter:tooltip(raw)
    assert(type(raw) == 'table', 'Lua view tooltip requires a table')
    return text_value(raw.tooltip)
end

---Returns adapter-specific optional inspection fields for one Lua view.
---@param raw table
---@return table
function LuaViewAdapter:optional_fields(raw)
    assert(type(raw) == 'table',
        'Lua view optional inspection fields require a table')
    return {}
end

---Returns the existing stable Lua-view inspection schema.
---@param raw table
---@return table
function LuaViewAdapter:inspect(raw)
    assert(type(raw) == 'table', 'Lua view inspection requires a table')
    local result = {
        class=self:native_type(raw),
        view_id=self:name(raw),
        visible=self:visible(raw),
        active=self:active(raw),
        focused=self:focused(raw),
        frame=copy_rect(raw.frame_rect),
        body=copy_rect(self:bounds(raw)),
        text=self:text(raw),
        tooltip=self:tooltip(raw),
    }
    for name, value in pairs(self:optional_fields(raw)) do
        result[name] = value
    end
    return result
end

---Releases the adapter root without mutating the Lua component.
---@return boolean
function LuaViewAdapter:cleanup()
    if self._cleaned then return false end
    self._cleaned = true
    self._root = nil
    return true
end

---Creates a subject adapter rooted at one exact Lua component.
---@param root table
---@return dwarfspec.LuaViewAdapter
function M.new(root)
    assert(type(root) == 'table',
        'Lua view subject adapter requires a root table')
    return setmetatable({
        _root=root,
        _cleaned=false,
    }, LuaViewAdapter)
end

---Creates a component subject source backed by a Lua-view adapter.
---@param root table
---@return dwarfspec.SubjectSource
function M.new_source(root)
    return {adapter=M.new(root)}
end

return M
