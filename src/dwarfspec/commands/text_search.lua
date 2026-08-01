-- Rendered-text search command validation and rectangle primitives.

local M = {}

local EMPTY_INTERSECTION = {}
M.EMPTY_INTERSECTION = EMPTY_INTERSECTION

local QUERY_FIELDS = {
    occurrence=true,
    text=true,
}

---Returns whether a value is an integer.
---@param value any
---@return boolean
local function is_integer(value)
    return type(value) == 'number' and value % 1 == 0
end

---Reads one exact byte from a screen pen or returns an unreadable sentinel.
---@param pen any
---@return integer|nil
local function readable_byte(pen)
    local pen_type = type(pen)
    if pen_type ~= 'table' and pen_type ~= 'userdata' then return nil end
    local ok, ch = pcall(function() return pen.ch end)
    if not ok or not is_integer(ch) or ch < 0 or ch > 255 then return nil end
    return ch
end

---Formats one normalized rectangle for a bounded diagnostic.
---@param rectangle table
---@return string
local function format_rectangle(rectangle)
    return ('{x1=%d,y1=%d,x2=%d,y2=%d}'):format(
        rectangle.x1, rectangle.y1, rectangle.x2, rectangle.y2)
end

---Validates and copies one rendered-text search query.
---@param query any
---@return table
function M.normalize_query(query)
    assert(type(query) == 'table',
        'text search query must be a table')
    for field in pairs(query) do
        assert(QUERY_FIELDS[field],
            'text search query contains unknown field: ' .. tostring(field))
    end

    assert(type(query.text) == 'string' and query.text ~= '',
        'text search query.text must be a nonempty string')
    assert(not query.text:find('\0', 1, true),
        'text search query.text must not contain NUL bytes')
    assert(not query.text:find('\r', 1, true),
        'text search query.text must not contain carriage-return bytes')
    assert(not query.text:find('\n', 1, true),
        'text search query.text must not contain newline bytes')

    local occurrence = query.occurrence
    if occurrence == nil then occurrence = 1 end
    assert(is_integer(occurrence) and occurrence >= 1,
        'text search query.occurrence must be a positive integer')

    return {
        text=query.text,
        occurrence=occurrence,
    }
end

---Validates and copies one zero-based inclusive rectangle.
---@param rectangle any
---@param label? string Diagnostic label; defaults to "text search rectangle".
---@return table
function M.normalize_rectangle(rectangle, label)
    label = label or 'text search rectangle'
    assert(type(rectangle) == 'table', label .. ' must be a table')

    local normalized = {}
    for _, field in ipairs({'x1', 'y1', 'x2', 'y2'}) do
        local value = rectangle[field]
        assert(is_integer(value),
            label .. '.' .. field .. ' must be an integer')
        normalized[field] = value
    end
    assert(normalized.x1 <= normalized.x2,
        label .. ' must not be horizontally inverted')
    assert(normalized.y1 <= normalized.y2,
        label .. ' must not be vertically inverted')
    return normalized
end

---Intersects two inclusive rectangles or returns the empty-result sentinel.
---@param first any
---@param second any
---@return table
function M.intersect_rectangles(first, second)
    local left = M.normalize_rectangle(
        first, 'first text search rectangle')
    local right = M.normalize_rectangle(
        second, 'second text search rectangle')
    local intersection = {
        x1=math.max(left.x1, right.x1),
        y1=math.max(left.y1, right.y1),
        x2=math.min(left.x2, right.x2),
        y2=math.min(left.y2, right.y2),
    }
    if intersection.x1 > intersection.x2 or
            intersection.y1 > intersection.y2 then
        return EMPTY_INTERSECTION
    end
    return intersection
end

---Returns whether a value is the distinct empty-intersection result.
---@param value any
---@return boolean
function M.is_empty_intersection(value)
    return value == EMPTY_INTERSECTION
end

---Constructs a rendered-cell text-search command from screen dependencies.
---@param dependencies table
---@return fun(query:any, scope:any):table|nil
function M.new(dependencies)
    assert(type(dependencies) == 'table',
        'text search command requires dependencies')
    local get_window_size = assert(dependencies.get_window_size,
        'text search command requires window-size access')
    local read_tile = assert(dependencies.read_tile,
        'text search command requires tile-reading access')
    assert(type(get_window_size) == 'function',
        'text search window-size access must be a function')
    assert(type(read_tile) == 'function',
        'text search tile-reading access must be a function')

    ---Searches one normalized screen scope in row-major order.
    ---@param query any
    ---@param scope any|nil Defaults to the captured current window.
    ---@return table|nil
    local function search(query, scope)
        local normalized_query = M.normalize_query(query)

        local width, height = get_window_size()
        assert(is_integer(width) and width > 0 and
                is_integer(height) and height > 0,
            ('text search received invalid window dimensions: ' ..
                'width=%s height=%s'):format(
                    tostring(width), tostring(height)))
        local window = {
            x1=0,
            y1=0,
            x2=width - 1,
            y2=height - 1,
        }
        local effective = window
        if scope ~= nil then
            local normalized_scope =
                M.normalize_rectangle(scope, 'text search scope')
            effective = M.intersect_rectangles(normalized_scope, window)
        end
        if M.is_empty_intersection(effective) then
            return EMPTY_INTERSECTION
        end

        local readable_cell_seen = false
        local remaining = normalized_query.occurrence
        for y = effective.y1, effective.y2 do
            local bytes = {}
            for x = effective.x1, effective.x2 do
                local ch = readable_byte(read_tile(x, y))
                if ch == nil then
                    bytes[#bytes + 1] = '\0'
                else
                    readable_cell_seen = true
                    bytes[#bytes + 1] = string.char(ch)
                end
            end

            local row = table.concat(bytes)
            local start = 1
            while true do
                local found = row:find(
                    normalized_query.text, start, true)
                if found == nil then break end
                remaining = remaining - 1
                if remaining == 0 then
                    local x1 = effective.x1 + found - 1
                    return {
                        x1=x1,
                        y1=y,
                        x2=x1 + #normalized_query.text - 1,
                        y2=y,
                    }
                end
                start = found + 1
            end
        end

        assert(readable_cell_seen,
            'text search effective region has no readable screen cells: ' ..
                format_rectangle(effective))
        return nil
    end

    return search
end

---Returns whether a value carries a retained Subject identity.
---@param mount_context table
---@param value any
---@return boolean
local function is_search_subject(mount_context, value)
    return type(value) == 'table' and
        (mount_context.subject_mounts[value] ~= nil or
            (type(value.mount_id) == 'number' and
                type(value.control_path) == 'string' and
                type(value._references) == 'table'))
end

---Returns validated visible body bounds for one resolved search subject.
---@param view any
---@param adapter dwarfspec.SubjectAdapter
---@param control_path string
---@return table
local function search_subject_scope(view, adapter, control_path)
    local visible = true
    if type(adapter.effective_visible) == 'function' then
        visible = adapter:effective_visible(view)
    elseif type(adapter.visible) == 'function' then
        visible = adapter:visible(view)
    end
    assert(visible,
        ('DwarfSpec search requires an effectively visible subject: ' ..
            'control_path=%q'):format(control_path))

    local bounds
    if type(adapter.interaction_bounds) == 'function' then
        bounds = adapter:interaction_bounds(view)
    end
    if bounds == nil then bounds = adapter:bounds(view) end
    assert(type(bounds) == 'table',
        ('DwarfSpec search subject has no visible body bounds: ' ..
            'control_path=%q'):format(control_path))
    return M.normalize_rectangle(bounds, 'text search subject bounds')
end

---Returns the current mount's default rendered-text search scope.
---@param mount table
---@return table|nil, boolean
local function default_search_scope(mount)
    if mount.category == 'native' then return nil, false end
    local adapter = mount.subject_source.adapter
    return search_subject_scope(
        adapter:root(), adapter, '<root>'), true
end

---Resolves an explicit subject or rectangle against the mount default.
---@param mount_context table
---@param default_scope table|nil
---@param search_area any
---@return table, boolean
local function explicit_search_scope(
        mount_context, default_scope, search_area)
    local requested
    local subject_scoped = false
    if is_search_subject(mount_context, search_area) then
        local view = mount_context:resolve_subject(search_area, 'search')
        requested = search_subject_scope(
            view, search_area._descriptor.adapter,
            search_area.control_path)
        subject_scoped = true
    else
        requested = M.normalize_rectangle(
            search_area, 'text search area')
    end
    if default_scope ~= nil then
        requested = M.intersect_rectangles(default_scope, requested)
    end
    if M.is_empty_intersection(requested) then
        assert(not subject_scoped,
            ('DwarfSpec search subject has no usable visible body ' ..
                'bounds within the current mount: control_path=%q')
                :format(search_area.control_path))
    end
    return requested, subject_scoped
end

---Constructs the public rendered-text search command.
---@param dependencies table
---@return fun(query:any, search_area:any|nil):table|nil
function M.new_command(dependencies)
    assert(type(dependencies) == 'table',
        'text search command requires dependencies')
    local mount_context = assert(dependencies.mount_context,
        'text search command requires mount-context access')
    local matcher = assert(dependencies.matcher,
        'text search command requires rendered matching')
    assert(type(matcher) == 'function',
        'text search rendered matching must be a function')

    ---Searches final rendered screen cells within the current mount scope.
    ---@param query any
    ---@param search_area any|nil
    ---@return table|nil
    local function search(query, search_area)
        local mount = mount_context:require_current('search')
        mount.interaction_target:assert_current('search')
        local normalized_query = M.normalize_query(query)
        local scope, subject_scoped = default_search_scope(mount)
        if search_area ~= nil then
            scope, subject_scoped = explicit_search_scope(
                mount_context, scope, search_area)
            if M.is_empty_intersection(scope) then return nil end
        end
        local result = matcher(normalized_query, scope)
        if M.is_empty_intersection(result) then
            assert(not subject_scoped,
                'DwarfSpec search subject has no usable visible body ' ..
                    'bounds within the current window')
            return nil
        end
        return result
    end

    return search
end

return M
