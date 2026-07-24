-- Native DF widget traversal and retained typed-reference identity.

local ESubjectSource = require('dwarfspec.subject_sources')

local M = {}

local DEFAULT_CHILD_SUMMARY_LIMIT = 12
local DEFAULT_LABEL_LIMIT = 80

---@class dwarfspec.NativeWidgetAdapter: dwarfspec.SubjectAdapter
---@field _root any|nil
---@field _interaction_target dwarfspec.BorrowedNativeInteractionTarget|nil
---@field _get_widget function|nil
---@field _get_children function|nil
---@field _identity_of function|nil
---@field _name_of function|nil
---@field _type_of function|nil
---@field _known_identities any[]
---@field _child_summary_limit integer
---@field _cleaned boolean
local NativeWidgetAdapter = {}
NativeWidgetAdapter.__index = NativeWidgetAdapter

---Returns a bounded scalar label for native lookup diagnostics.
---@param value any
---@return string
local function bounded_label(value)
    local label = tostring(value)
    if #label <= DEFAULT_LABEL_LIMIT then return label end
    return label:sub(1, DEFAULT_LABEL_LIMIT - 3) .. '...'
end

---Formats one native path segment without losing its scalar type.
---@param segment dwarfspec.NativePathSegment
---@return string
local function format_segment(segment)
    if type(segment) == 'string' then return ('%q'):format(segment) end
    return tostring(segment)
end

---Formats a complete normalized native path for stable diagnostics.
---@param path_segments dwarfspec.NativePathSegment[]
---@return string
local function format_path(path_segments)
    local formatted = {}
    for _, segment in ipairs(path_segments) do
        table.insert(formatted, format_segment(segment))
    end
    return '{' .. table.concat(formatted, ', ') .. '}'
end

---Returns the exact root after validating pinned-screen currentness.
---@param self dwarfspec.NativeWidgetAdapter
---@param operation string
---@return any
local function require_root(self, operation)
    assert(not self._cleaned and self._root ~= nil and
        self._interaction_target,
        operation .. ' native subject source is no longer available')
    self._interaction_target:assert_current(operation)
    return self._root
end

---Returns whether a captured identity has already been reached from the root.
---@param self dwarfspec.NativeWidgetAdapter
---@param identity any
---@return boolean
local function identity_is_known(self, identity)
    for _, known in ipairs(self._known_identities) do
        if known == identity then return true end
    end
    return false
end

---Retains one stable identity reached through the pinned native hierarchy.
---@param self dwarfspec.NativeWidgetAdapter
---@param raw any
local function remember(self, raw)
    local identity = self._identity_of(raw)
    assert(identity ~= nil,
        'native widget identity access returned nil')
    if not identity_is_known(self, identity) then
        table.insert(self._known_identities, identity)
    end
end

---Returns the exact pinned native widget container.
---@return any
function NativeWidgetAdapter:root()
    return require_root(self, 'native root access')
end

---Resolves every segment through one separate native getWidget call.
---@param path_segments dwarfspec.NativePathSegment[]
---@return any|nil, table|nil
function NativeWidgetAdapter:resolve(path_segments)
    assert(type(path_segments) == 'table',
        'native subject resolution requires path segments')
    local parent = require_root(self, 'native subject resolution')
    if #path_segments == 0 then return parent end
    for index, segment in ipairs(path_segments) do
        self._interaction_target:assert_current('native widget lookup')
        local ok, child = pcall(self._get_widget, parent, segment)
        assert(ok,
            ('DwarfSpec native widget lookup failed at segment %d=%s: %s')
                :format(index, format_segment(segment), tostring(child)))
        if child == nil then
            return nil, {
                index=index,
                segment=segment,
                parent=parent,
            }
        end
        self._interaction_target:assert_current('native widget lookup')
        remember(self, child)
        parent = child
    end
    return parent
end

---Returns the stable typed-reference identity for one reached widget.
---@param raw any
---@return any
function NativeWidgetAdapter:identity(raw)
    require_root(self, 'native subject identity')
    local identity = self._identity_of(raw)
    assert(identity ~= nil,
        'native widget identity access returned nil')
    return identity
end

---Returns whether an object's identity was reached from the pinned root.
---@param raw any
---@return boolean
function NativeWidgetAdapter:contains(raw)
    require_root(self, 'native subject containment')
    return identity_is_known(self, self._identity_of(raw))
end

---Enumerates native children in the exact order returned by DFHack.
---@param raw any
---@return table
function NativeWidgetAdapter:children(raw)
    require_root(self, 'native child enumeration')
    assert(self:contains(raw),
        'native widget adapter cannot enumerate an unrelated object')
    self._interaction_target:assert_current('native child enumeration')
    local ok, children = pcall(self._get_children, raw)
    assert(ok,
        'DwarfSpec native child enumeration failed: ' .. tostring(children))
    assert(type(children) == 'table',
        'DwarfSpec native child enumeration must return an ordered table')
    self._interaction_target:assert_current('native child enumeration')
    local result = {}
    for index, child in ipairs(children) do
        remember(self, child)
        result[index] = child
    end
    return result
end

---Returns the exact native widget name or nil for an unnamed widget.
---@param raw any
---@return string|nil
function NativeWidgetAdapter:name(raw)
    require_root(self, 'native widget name access')
    if self._identity_of(raw) == self._identity_of(self._root) then
        return '<native-root>'
    end
    local value = self._name_of(raw)
    if value == nil then return nil end
    return tostring(value)
end

---Returns a stable native widget type label.
---@param raw any
---@return string
function NativeWidgetAdapter:native_type(raw)
    require_root(self, 'native widget type access')
    return bounded_label(self._type_of(raw) or '<unknown-native-widget>')
end

---Returns no bounds until native geometry normalization is installed.
---@param raw any
---@return nil
function NativeWidgetAdapter:bounds(raw)
    assert(self:contains(raw),
        'native widget adapter cannot read bounds from an unrelated object')
    return nil
end

---Returns a temporary direct visibility value without filtering lookup.
---@param raw any
---@return boolean
function NativeWidgetAdapter:visible(raw)
    assert(self:contains(raw),
        'native widget adapter cannot inspect an unrelated object')
    return true
end

---Returns a temporary direct activity value without filtering lookup.
---@param raw any
---@return boolean
function NativeWidgetAdapter:active(raw)
    assert(self:contains(raw),
        'native widget adapter cannot inspect an unrelated object')
    return true
end

---Returns whether the native widget itself owns focus.
---@param raw any
---@return boolean
function NativeWidgetAdapter:focused(raw)
    assert(self:contains(raw),
        'native widget adapter cannot inspect an unrelated object')
    return false
end

---Returns no text until type-aware native extraction is installed.
---@param raw any
---@return nil
function NativeWidgetAdapter:text(raw)
    assert(self:contains(raw),
        'native widget adapter cannot inspect an unrelated object')
    return nil
end

---Returns no tooltip until native tooltip extraction is installed.
---@param raw any
---@return nil
function NativeWidgetAdapter:tooltip(raw)
    assert(self:contains(raw),
        'native widget adapter cannot inspect an unrelated object')
    return nil
end

---Returns no optional fields until native inspection is installed.
---@param raw any
---@return table
function NativeWidgetAdapter:optional_fields(raw)
    assert(self:contains(raw),
        'native widget adapter cannot inspect an unrelated object')
    return {}
end

---Returns one bounded minimal native widget inspection record.
---@param raw any
---@return table
function NativeWidgetAdapter:inspect(raw)
    return {
        class=self:native_type(raw),
        view_id=self:name(raw),
        visible=self:visible(raw),
        active=self:active(raw),
        focused=self:focused(raw),
        frame=nil,
        body=nil,
        text=nil,
        tooltip=nil,
    }
end

---Formats a bounded deterministic child summary for one failed lookup.
---@param failure table
---@param path_segments dwarfspec.NativePathSegment[]
---@return string
function NativeWidgetAdapter:format_resolution_failure(
        failure, path_segments)
    require_root(self, 'native lookup diagnostics')
    local parent = failure.parent
    local parent_name = self:name(parent) or '<unnamed>'
    local parent_type = self:native_type(parent)
    local children = self:children(parent)
    local indexed = {}
    local named = {}
    local named_total = 0
    for index, child in ipairs(children) do
        local zero_index = index - 1
        local child_name = self:name(child)
        local child_type = self:native_type(child)
        if index <= self._child_summary_limit then
            table.insert(indexed, ('%d:{name=%q,type=%q}'):format(
                zero_index, bounded_label(child_name or '<unnamed>'),
                child_type))
        end
        if child_name and child_name ~= '' then
            named_total = named_total + 1
            if #named < self._child_summary_limit then
                table.insert(named, ('%q:{index=%d,type=%q}'):format(
                    bounded_label(child_name), zero_index, child_type))
            end
        end
    end
    if #children > self._child_summary_limit then
        table.insert(indexed, ('... (+%d more)'):format(
            #children - self._child_summary_limit))
    end
    if named_total > self._child_summary_limit then
        table.insert(named, ('... (+%d more)'):format(
            named_total - self._child_summary_limit))
    end
    return ('native_path=%s missing segment[%d]=%s; parent_name=%q ' ..
        'parent_type=%q; named children=[%s]; indexed children=[%s]')
        :format(format_path(path_segments), failure.index,
            format_segment(failure.segment), bounded_label(parent_name),
            parent_type, table.concat(named, ', '),
            table.concat(indexed, ', '))
end

---Releases the borrowed native root, services, and retained identities.
---@return boolean
function NativeWidgetAdapter:cleanup()
    if self._cleaned then return false end
    self._cleaned = true
    self._root = nil
    self._interaction_target = nil
    self._get_widget = nil
    self._get_children = nil
    self._identity_of = nil
    self._name_of = nil
    self._type_of = nil
    self._known_identities = {}
    return true
end

---Creates a native widget adapter over injected DFHack widget services.
---@param root any
---@param interaction_target dwarfspec.BorrowedNativeInteractionTarget
---@param options table
---@return dwarfspec.NativeWidgetAdapter
function M.new(root, interaction_target, options)
    assert(root ~= nil, 'native widget adapter requires a widget container')
    assert(type(interaction_target) == 'table' and
        type(interaction_target.assert_current) == 'function',
        'native widget adapter requires an interaction target')
    assert(type(options) == 'table',
        'native widget adapter requires dependency options')
    assert(type(options.get_widget) == 'function',
        'native widget adapter requires getWidget access')
    assert(type(options.get_children) == 'function',
        'native widget adapter requires getWidgetChildren access')
    local identity_of = options.identity_of or
        function(raw) return raw end
    local name_of = options.name_of or function(raw)
        local ok, value = pcall(function() return raw.name end)
        if ok then return value end
        return nil
    end
    local type_of = options.type_of or function(raw)
        local ok, value = pcall(function() return raw._type end)
        if not ok or value == nil then return type(raw) end
        if type(value) == 'table' then
            return value._name or value.name or tostring(value)
        end
        return tostring(value)
    end
    assert(type(identity_of) == 'function',
        'native widget adapter identity access must be callable')
    assert(type(name_of) == 'function',
        'native widget adapter name access must be callable')
    assert(type(type_of) == 'function',
        'native widget adapter type access must be callable')
    local adapter = setmetatable({
        _root=root,
        _interaction_target=interaction_target,
        _get_widget=options.get_widget,
        _get_children=options.get_children,
        _identity_of=identity_of,
        _name_of=name_of,
        _type_of=type_of,
        _known_identities={},
        _child_summary_limit=options.child_summary_limit or
            DEFAULT_CHILD_SUMMARY_LIMIT,
        _cleaned=false,
    }, NativeWidgetAdapter)
    assert(type(adapter._child_summary_limit) == 'number' and
        adapter._child_summary_limit >= 1 and
        adapter._child_summary_limit % 1 == 0,
        'native child summary limit must be a positive integer')
    interaction_target:assert_current('native widget adapter creation')
    remember(adapter, root)
    return adapter
end

---Creates the default native source for one pinned widget hierarchy.
---@param root any
---@param interaction_target dwarfspec.BorrowedNativeInteractionTarget
---@param options table
---@return dwarfspec.SubjectSource
function M.new_source(root, interaction_target, options)
    return {
        kind=ESubjectSource.NATIVE,
        adapter=M.new(root, interaction_target, options),
    }
end

return M
