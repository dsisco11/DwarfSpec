-- Presentation-neutral source-location extraction for Busted problems.

local M = {}

local MAX_TRACE_BYTES = 65536
local MAX_TRACE_LINES = 128

---Returns whether one number is a positive integer.
---@param value any
---@return boolean
local function is_positive_integer(value)
    return type(value) == 'number' and value > 0 and value % 1 == 0
end

---Lexically normalizes one path without consulting the filesystem.
---@param path string
---@return string|nil
local function normalize_path(path)
    local value = path:gsub('^@', ''):gsub('\\', '/'):gsub('/+', '/')
    if value == '' or value:match('^%[') then return nil end

    local prefix = ''
    local remainder = value
    local drive = value:match('^([A-Za-z]:)/')
    if drive then
        prefix = drive:upper() .. '/'
        remainder = value:sub(4)
    elseif value:sub(1, 1) == '/' then
        prefix = '/'
        remainder = value:sub(2)
    end

    local segments = {}
    for segment in remainder:gmatch('[^/]+') do
        if segment == '..' then
            if #segments == 0 then return nil end
            table.remove(segments)
        elseif segment ~= '.' and segment ~= '' then
            table.insert(segments, segment)
        end
    end
    return prefix .. table.concat(segments, '/')
end

---Returns whether a normalized path is absolute.
---@param path string
---@return boolean
local function is_absolute(path)
    return path:sub(1, 1) == '/' or
        path:match('^[A-Za-z]:/') ~= nil
end

---Returns whether path comparison should ignore case.
---@param path string
---@return boolean
local function is_case_insensitive(path)
    return path:match('^[A-Za-z]:/') ~= nil
end

---Returns one comparison key for a normalized path.
---@param path string
---@param insensitive boolean
---@return string
local function comparison_key(path, insensitive)
    return insensitive and path:lower() or path
end

---Returns a project-relative identity for one candidate path.
---@param project_root string
---@param source string
---@return string|nil
local function project_relative(project_root, source)
    local root = normalize_path(project_root)
    local candidate = normalize_path(source)
    if root == nil or candidate == nil then return nil end
    if not is_absolute(candidate) then return candidate end
    if not is_absolute(root) then return nil end

    local insensitive = is_case_insensitive(root)
    local root_key = comparison_key(root, insensitive)
    local candidate_key = comparison_key(candidate, insensitive)
    if candidate_key == root_key then return nil end
    local prefix = root_key:gsub('/$', '') .. '/'
    if candidate_key:sub(1, #prefix) ~= prefix then return nil end
    return candidate:sub(#root:gsub('/$', '') + 2)
end

---Returns whether one project-relative identity is an implementation frame.
---@param identity string
---@return boolean
local function is_internal(identity)
    local value = identity:lower()
    return value:match('^src/dwarfspec/') ~= nil or
        value:match('^lua/dwarfspec/') ~= nil or
        value:match('^%.luarocks/') ~= nil or
        value:match('/busted/') ~= nil or
        value:match('/luassert/') ~= nil or
        value:match('^busted/') ~= nil or
        value:match('^luassert/') ~= nil
end

---Returns a trustworthy canonical source identity.
---@param project_root string
---@param source any
---@return string|nil
local function eligible_identity(project_root, source)
    if type(source) ~= 'string' or source == '' then return nil end
    local identity = project_relative(project_root, source)
    if identity == nil or identity == '' or is_internal(identity) then
        return nil
    end
    return identity
end

---Returns a location record for a trustworthy source and line.
---@param project_root string
---@param source any
---@param line any
---@param column any
---@return table|nil
local function location(project_root, source, line, column)
    local identity = eligible_identity(project_root, source)
    if identity == nil or not is_positive_integer(line) then return nil end
    local result = {source_identity=identity, line=line}
    if is_positive_integer(column) then result.column = column end
    return result
end

---Returns a structured trace location from source and short-source fields.
---@param project_root string
---@param trace table
---@return table|nil
local function structured_location(project_root, trace)
    return location(project_root, trace.source,
        trace.currentline, trace.currentcolumn or trace.column) or
        location(project_root, trace.short_src,
            trace.currentline, trace.currentcolumn or trace.column)
end

---Returns source and line candidates encoded in one trace line.
---@param text string
---@return string|nil, integer|nil, integer|nil
local function parse_trace_line(text)
    local source, line, column =
        text:match('^%s*(.-):(%d+):(%d+):')
    if source ~= nil then
        return source, tonumber(line), tonumber(column)
    end
    source, line = text:match('^%s*(.-):(%d+):')
    if source == nil then return nil end
    return source, tonumber(line), nil
end

---Returns bounded trustworthy locations parsed from rendered trace text.
---@param project_root string
---@param trace_text string
---@return table[]
local function parsed_locations(project_root, trace_text)
    local results = {}
    local bounded = trace_text:sub(1, MAX_TRACE_BYTES)
    local line_count = 0
    for text in (bounded .. '\n'):gmatch('(.-)\r?\n') do
        line_count = line_count + 1
        if line_count > MAX_TRACE_LINES then break end
        local source, line, column = parse_trace_line(text)
        local candidate = location(project_root, source, line, column)
        if candidate ~= nil then table.insert(results, candidate) end
    end
    return results
end

---Returns the selected test's canonical source identity when available.
---@param project_root string
---@param selected_source_identity any
---@param element table
---@return string|nil
local function selected_identity(project_root, selected_source_identity,
        element)
    local element_trace = type(element.trace) == 'table' and
        element.trace or {}
    return eligible_identity(project_root, selected_source_identity) or
        eligible_identity(project_root, element.source) or
        eligible_identity(project_root, element.short_src) or
        eligible_identity(project_root, element_trace.source) or
        eligible_identity(project_root, element_trace.short_src)
end

---Returns the preferred parsed trace location.
---@param candidates table[]
---@param selected string|nil
---@return table|nil
local function preferred_location(candidates, selected)
    if selected ~= nil then
        for _, candidate in ipairs(candidates) do
            if candidate.source_identity == selected then return candidate end
        end
    end
    return candidates[1]
end

---Extracts a canonical project-owned source location from a Busted problem.
---@param project_root string
---@param selected_source_identity string|nil
---@param element table
---@param trace table|string|nil
---@return table|nil
function M.extract(project_root, selected_source_identity, element, trace)
    assert(type(project_root) == 'string' and project_root ~= '',
        'problem project root must be a nonempty string')
    assert(type(element) == 'table',
        'problem element must be a table')

    local selected = selected_identity(
        project_root, selected_source_identity, element)
    if type(trace) == 'table' then
        local structured = structured_location(project_root, trace)
        if structured ~= nil then return structured end
    end

    local rendered = type(trace) == 'string' and trace or
        type(trace) == 'table' and trace.traceback or nil
    if type(rendered) == 'string' then
        local parsed = preferred_location(
            parsed_locations(project_root, rendered), selected)
        if parsed ~= nil then return parsed end
    end

    local element_trace = type(element.trace) == 'table' and
        element.trace or {}
    local line = element.currentline or element.line or
        element_trace.currentline
    local column = element.currentcolumn or element.column or
        element_trace.currentcolumn or element_trace.column
    return location(project_root, element.source, line, column) or
        location(project_root, element.short_src, line, column) or
        location(project_root, element_trace.source, line, column) or
        location(project_root, element_trace.short_src, line, column)
end

return M
