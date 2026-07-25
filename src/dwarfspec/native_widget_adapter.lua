-- Native DF widget traversal and retained typed-reference identity.

local ESubjectSource = require('dwarfspec.subject_sources')

local M = {}

local DEFAULT_CHILD_SUMMARY_LIMIT = 12
local DEFAULT_LABEL_LIMIT = 80
local DEFAULT_TEXT_LIMIT = 512
local DEFAULT_TEXT_DEPTH_LIMIT = 4
local DEFAULT_TEXT_NODE_LIMIT = 64
local DEFAULT_PARENT_LIMIT = 64

---Maps exact supported native widget types to their read-only text field.
---@type table<string, string>
local TEXT_TYPES = {
    ['df.widget_text']='str',
    ['df.widget_textst']='str',
    ['df.widget_text_truncated']='str',
    ['df.widget_text_truncatedst']='str',
    ['df.widget_text_multiline']='str',
    ['df.widget_text_multilinest']='str',
    ['df.widget_textbox']='str',
    ['df.widget_textboxst']='str',
}

---Identifies native button types with a documented display-string accessor.
---@type table<string, boolean>
local BETTER_BUTTON_TYPES = {
    ['df.widget_better_button']=true,
    ['df.widget_better_buttonst']=true,
}

---Maps exact selectable native widget types to their selected-index field.
---@type table<string, string>
local SELECTION_FIELDS = {
    ['df.widget_tabs']='cur_idx',
    ['df.widget_tabsst']='cur_idx',
    ['df.widget_dropdown']='cur_selected',
    ['df.widget_dropdownst']='cur_selected',
    ['df.widget_radio_rows']='selected_idx',
    ['df.widget_radio_rowsst']='selected_idx',
}

---@class dwarfspec.NativeWidgetAdapter: dwarfspec.SubjectAdapter
---@field _root any|nil
---@field _interaction_target dwarfspec.BorrowedNativeInteractionTarget|nil
---@field _get_widget function|nil
---@field _get_children function|nil
---@field _is_container function|nil
---@field _identity_of function|nil
---@field _name_of function|nil
---@field _type_of function|nil
---@field _get_window_size function|nil
---@field _known_identities any[]
---@field _child_summary_limit integer
---@field _text_limit integer
---@field _text_depth_limit integer
---@field _text_node_limit integer
---@field _cleaned boolean
local NativeWidgetAdapter = {}
NativeWidgetAdapter.__index = NativeWidgetAdapter

---Reads one native field without propagating userdata access failures.
---@param raw any
---@param field string
---@return any
local function safe_field(raw, field)
    local ok, value = pcall(function() return raw[field] end)
    if ok then return value end
    return nil
end

---Copies a valid integral inclusive rectangle into a plain table.
---@param rect any
---@return table|nil
local function normalize_rect(rect)
    if rect == nil then return nil end
    local values = {}
    for _, field in ipairs({'x1', 'y1', 'x2', 'y2'}) do
        local value = safe_field(rect, field)
        if type(value) ~= 'number' or value % 1 ~= 0 then return nil end
        values[field] = value
    end
    if values.x1 > values.x2 or values.y1 > values.y2 then return nil end
    return values
end

---Returns a bounded string without inspecting arbitrary compound values.
---@param value any
---@param limit integer
---@return string|nil
local function bounded_text(value, limit)
    if value == nil then return nil end
    local value_type = type(value)
    if value_type ~= 'string' and value_type ~= 'number' and
            value_type ~= 'boolean' then
        return nil
    end
    local result = tostring(value)
    if #result <= limit then return result end
    if limit <= 3 then return result:sub(1, limit) end
    return result:sub(1, limit - 3) .. '...'
end

---Returns a native flag value without evaluating any callbacks.
---@param raw any
---@param flag_name string
---@return boolean
local function read_flag(raw, flag_name)
    local flags = safe_field(raw, 'flag')
    if flags == nil then return false end
    return not not safe_field(flags, flag_name)
end

---Returns an unusable window when geometry services were not injected.
---@return integer, integer
local function unavailable_window_size()
    return 0, 0
end

---Normalizes DFHack type descriptors to canonical df-prefixed names.
---@param value any
---@return string
local function normalize_native_type(value)
    local label = tostring(value)
    local descriptor = label:match('^<type:%s*([%w_%.]+)>$')
    if descriptor then
        if descriptor:match('^df%.') then return descriptor end
        return 'df.' .. descriptor
    end
    return label
end

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
    local ok, is_container = pcall(self._is_container, raw)
    assert(ok,
        'DwarfSpec native container test failed: ' .. tostring(is_container))
    assert(type(is_container) == 'boolean',
        'DwarfSpec native container test must return a boolean')
    self._interaction_target:assert_current('native child enumeration')
    if not is_container then return {} end
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

---Returns current normalized zero-based inclusive native widget bounds.
---@param raw any
---@return table|nil
function NativeWidgetAdapter:bounds(raw)
    assert(self:contains(raw),
        'native widget adapter cannot read bounds from an unrelated object')
    local rect
    local get_rect = safe_field(raw, 'get_rect')
    if type(get_rect) == 'function' then
        self._interaction_target:assert_current('native widget geometry')
        local ok, value = pcall(get_rect, raw)
        self._interaction_target:assert_current('native widget geometry')
        if ok then rect = value end
    end
    if rect == nil then rect = safe_field(raw, 'rect') end
    return normalize_rect(rect)
end

---Returns bounds clipped to the current window for pointer interaction.
---@param raw any
---@return table|nil
function NativeWidgetAdapter:interaction_bounds(raw)
    local rect = self:bounds(raw)
    if rect == nil then return nil end
    self._interaction_target:assert_current('native window geometry')
    local ok, width, height = pcall(self._get_window_size)
    self._interaction_target:assert_current('native window geometry')
    assert(ok, 'DwarfSpec native window geometry failed: ' ..
        tostring(width))
    if type(width) ~= 'number' or type(height) ~= 'number' or
            width % 1 ~= 0 or height % 1 ~= 0 or
            width < 1 or height < 1 then
        return nil
    end
    local clipped = {
        x1=math.max(0, rect.x1),
        y1=math.max(0, rect.y1),
        x2=math.min(width - 1, rect.x2),
        y2=math.min(height - 1, rect.y2),
    }
    if clipped.x1 > clipped.x2 or clipped.y1 > clipped.y2 then return nil end
    return clipped
end

---Returns direct native visibility without filtering lookup.
---@param raw any
---@return boolean
function NativeWidgetAdapter:visible(raw)
    assert(self:contains(raw),
        'native widget adapter cannot inspect an unrelated object')
    return read_flag(raw, 'VISIBILITY_VISIBLE')
end

---Returns direct native activity without filtering lookup.
---@param raw any
---@return boolean
function NativeWidgetAdapter:active(raw)
    assert(self:contains(raw),
        'native widget adapter cannot inspect an unrelated object')
    return read_flag(raw, 'VISIBILITY_ACTIVE')
end

---Calculates effective native visibility or activity through the parent chain.
---@param self dwarfspec.NativeWidgetAdapter
---@param raw any
---@param flag_name string
---@return boolean
local function effective_flag(self, raw, flag_name)
    assert(self:contains(raw),
        'native widget adapter cannot inspect an unrelated object')
    local current = raw
    local visited = {}
    for _ = 1, DEFAULT_PARENT_LIMIT do
        local identity = self._identity_of(current)
        if visited[identity] then return false end
        visited[identity] = true
        if not read_flag(current, flag_name) then return false end
        if identity == self._identity_of(self._root) then return true end
        current = safe_field(current, 'parent')
        if current == nil then return true end
    end
    return false
end

---Returns inherited native visibility separately from the direct flag.
---@param raw any
---@return boolean
function NativeWidgetAdapter:effective_visible(raw)
    return effective_flag(self, raw, 'VISIBILITY_VISIBLE')
end

---Returns inherited native activity separately from the direct flag.
---@param raw any
---@return boolean
function NativeWidgetAdapter:effective_active(raw)
    return effective_flag(self, raw, 'VISIBILITY_ACTIVE')
end

---Returns whether the native widget itself owns focus.
---@param raw any
---@return boolean
function NativeWidgetAdapter:focused(raw)
    assert(self:contains(raw),
        'native widget adapter cannot inspect an unrelated object')
    return false
end

---Returns direct text for an explicitly supported native widget type.
---@param self dwarfspec.NativeWidgetAdapter
---@param raw any
---@return string|nil
local function direct_text(self, raw)
    local type_name = self:native_type(raw)
    local field = TEXT_TYPES[type_name]
    if field then
        return bounded_text(safe_field(raw, field), self._text_limit)
    end
    if BETTER_BUTTON_TYPES[type_name] then
        local display_string = safe_field(raw, 'display_string')
        if type(display_string) ~= 'function' then
            return bounded_text(display_string, self._text_limit)
        end
        self._interaction_target:assert_current(
            'native better-button text inspection')
        local ok, value = pcall(display_string, raw)
        self._interaction_target:assert_current(
            'native better-button text inspection')
        if ok then return bounded_text(value, self._text_limit) end
    end
    return nil
end

---Aggregates visible descendant text within fixed traversal limits.
---@param self dwarfspec.NativeWidgetAdapter
---@param raw any
---@return string|nil
local function descendant_text(self, raw)
    local parts = {}
    local state = {nodes=0, length=0}

    ---Visits one descendant without traversing arbitrary native fields.
    ---@param node any
    ---@param depth integer
    local function visit(node, depth)
        if depth > self._text_depth_limit or
                state.nodes >= self._text_node_limit or
                state.length >= self._text_limit then
            return
        end
        for _, child in ipairs(self:children(node)) do
            if state.nodes >= self._text_node_limit or
                    state.length >= self._text_limit then
                return
            end
            state.nodes = state.nodes + 1
            if self:visible(child) then
                local value = direct_text(self, child)
                if value ~= nil and value ~= '' then
                    local separator = #parts == 0 and '' or '\n'
                    local remaining = self._text_limit -
                        state.length - #separator
                    if remaining <= 0 then return end
                    local piece = value:sub(1, remaining)
                    table.insert(parts, separator .. piece)
                    state.length = state.length + #separator + #piece
                elseif depth < self._text_depth_limit then
                    visit(child, depth + 1)
                end
            end
        end
    end

    visit(raw, 1)
    if #parts == 0 then return nil end
    return table.concat(parts)
end

---Returns bounded type-aware text or visible descendant text.
---@param raw any
---@return string|nil
function NativeWidgetAdapter:text(raw)
    assert(self:contains(raw),
        'native widget adapter cannot inspect an unrelated object')
    return direct_text(self, raw) or descendant_text(self, raw)
end

---Returns scalar native tooltip text without invoking variant callbacks.
---@param raw any
---@return string|nil
function NativeWidgetAdapter:tooltip(raw)
    assert(self:contains(raw),
        'native widget adapter cannot inspect an unrelated object')
    return bounded_text(safe_field(raw, 'tooltip'), self._text_limit)
end

---Returns the documented bounded optional native inspection fields.
---@param raw any
---@return table
function NativeWidgetAdapter:optional_fields(raw)
    assert(self:contains(raw),
        'native widget adapter cannot inspect an unrelated object')
    local type_name = self:native_type(raw)
    local result = {
        native_type=type_name,
        name=self:name(raw),
        effective_visible=self:effective_visible(raw),
        effective_active=self:effective_active(raw),
    }
    if type_name == 'df.widget_scroll_rows' or
            type_name == 'df.widget_scroll_rowsst' then
        local scroll = safe_field(raw, 'scroll')
        local visible_rows = safe_field(raw, 'num_visible')
        if type(scroll) == 'number' and scroll % 1 == 0 then
            result.scroll_position = scroll
        end
        if type(visible_rows) == 'number' and visible_rows % 1 == 0 then
            result.visible_row_count = visible_rows
        end
    end
    local selection_field = SELECTION_FIELDS[type_name]
    local selected = selection_field and safe_field(raw, selection_field)
    if type(selected) == 'number' and selected % 1 == 0 then
        result.selected_index = selected
    end
    return result
end

---Returns one bounded read-only native widget inspection record.
---@param raw any
---@return table
function NativeWidgetAdapter:inspect(raw)
    local result = {
        class=self:native_type(raw),
        view_id=self:name(raw),
        visible=self:visible(raw),
        active=self:active(raw),
        focused=self:focused(raw),
        frame=nil,
        body=self:bounds(raw),
        text=self:text(raw),
        tooltip=self:tooltip(raw),
    }
    for name, value in pairs(self:optional_fields(raw)) do
        result[name] = value
    end
    return result
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
    self._is_container = nil
    self._identity_of = nil
    self._name_of = nil
    self._type_of = nil
    self._get_window_size = nil
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
    assert(type(options.is_container) == 'function',
        'native widget adapter requires widget-container type access')
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
            value = value._name or value.name or value
        end
        return normalize_native_type(value)
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
        _is_container=options.is_container,
        _identity_of=identity_of,
        _name_of=name_of,
        _type_of=type_of,
        _get_window_size=options.get_window_size or unavailable_window_size,
        _known_identities={},
        _child_summary_limit=options.child_summary_limit or
            DEFAULT_CHILD_SUMMARY_LIMIT,
        _text_limit=options.text_limit or DEFAULT_TEXT_LIMIT,
        _text_depth_limit=options.text_depth_limit or
            DEFAULT_TEXT_DEPTH_LIMIT,
        _text_node_limit=options.text_node_limit or
            DEFAULT_TEXT_NODE_LIMIT,
        _cleaned=false,
    }, NativeWidgetAdapter)
    assert(type(adapter._child_summary_limit) == 'number' and
        adapter._child_summary_limit >= 1 and
        adapter._child_summary_limit % 1 == 0,
        'native child summary limit must be a positive integer')
    for name, value in pairs({
        text_limit=adapter._text_limit,
        text_depth_limit=adapter._text_depth_limit,
        text_node_limit=adapter._text_node_limit,
    }) do
        assert(type(value) == 'number' and value >= 1 and value % 1 == 0,
            ('native %s must be a positive integer'):format(name))
    end
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
