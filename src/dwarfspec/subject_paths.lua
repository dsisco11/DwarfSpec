-- Path normalization contracts shared by component and native subjects.

local M = {}

---@alias dwarfspec.NativePathSegment string|integer
---@alias dwarfspec.NativePathSegmentArray dwarfspec.NativePathSegment[]

---Copies and validates one dense one-based caller array.
---@param path table
---@return table
local function copy_dense_array(path)
    local count = 0
    local maximum = 0
    for key in pairs(path) do
        assert(type(key) == 'number' and key >= 1 and key % 1 == 0,
            'native control path segment arrays must use positive integral ' ..
                'array positions')
        count = count + 1
        maximum = math.max(maximum, key)
    end
    assert(count > 0,
        'native control path segment array must contain at least one segment')
    assert(maximum == count,
        'native control path segment array must not contain gaps')

    local result = {}
    for index = 1, count do result[index] = path[index] end
    return result
end

---Validates one native widget path segment.
---@param segment any
---@param index integer
---@return dwarfspec.NativePathSegment
local function validate_native_segment(segment, index)
    if type(segment) == 'string' then
        assert(segment ~= '',
            ('native control path segment %d must be a nonempty string')
                :format(index))
        return segment
    end
    if type(segment) == 'number' then
        assert(segment >= 0 and segment % 1 == 0,
            ('native control path segment %d must be a nonnegative integer')
                :format(index))
        return segment
    end
    error(('native control path segment %d must be a nonempty string or ' ..
        'nonnegative integer; received %s'):format(index, type(segment)), 3)
end

---Normalizes one existing slash-delimited component control path.
---@param control_path any
---@return string[]
function M.component(control_path)
    assert(type(control_path) == 'string' and control_path ~= '',
        'control path must be a nonempty string')
    assert(control_path:sub(1, 1) ~= '/' and
        control_path:sub(-1) ~= '/',
        'control path cannot start or end with "/"')
    local segments = {}
    for segment in control_path:gmatch('[^/]+') do
        assert(segment ~= '.' and segment ~= '..',
            ('control path contains reserved segment %q'):format(segment))
        table.insert(segments, segment)
    end
    assert(#segments > 0, 'control path must contain at least one segment')
    return segments
end

---Normalizes an unambiguous native name or authoritative segment array.
---@param control_path any
---@return dwarfspec.NativePathSegmentArray
function M.native(control_path)
    if type(control_path) == 'string' then
        assert(control_path ~= '',
            'native control path must be a nonempty string or path-segment ' ..
                'array')
        assert(not control_path:find('/', 1, true),
            ('native string control path %q is ambiguous because native ' ..
            'widget names may contain "/"; use path-segment array syntax')
                :format(control_path))
        return {control_path}
    end
    assert(type(control_path) == 'table',
        'native control path must be a nonempty string or path-segment array')
    local segments = copy_dense_array(control_path)
    for index, segment in ipairs(segments) do
        segments[index] = validate_native_segment(segment, index)
    end
    return segments
end

---Formats a complete normalized native path for diagnostics.
---@param path_segments dwarfspec.NativePathSegmentArray
---@return string
function M.format_native(path_segments)
    assert(type(path_segments) == 'table',
        'native path formatting requires path segments')
    local formatted = {}
    for _, segment in ipairs(path_segments) do
        table.insert(formatted, type(segment) == 'string' and
            ('%q'):format(segment) or tostring(segment))
    end
    return '{' .. table.concat(formatted, ', ') .. '}'
end

return M
