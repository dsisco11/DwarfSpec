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

return M
