-- Pure platform-path operations shared by external project services.

local M = {}

---Returns the active platform path separator.
---@return string
local function separator()
    return package.config:sub(1, 1)
end

---Joins two path fragments with the active platform separator.
---@param root string
---@param relative_path string
---@return string
function M.join(root, relative_path)
    return root .. separator() .. relative_path:gsub('[/\\]', separator())
end

---Returns whether a path is absolute on Windows or Unix-like systems.
---@param path string
---@return boolean
function M.is_absolute(path)
    return path:match('^[/\\]') ~= nil or
        path:match('^[A-Za-z]:[/\\]') ~= nil
end

---Normalizes separators and removes harmless current-directory segments.
---@param path string
---@return string
function M.normalize(path)
    assert(type(path) == 'string' and path ~= '',
        'path must be a nonempty string')
    local normalized = path:gsub('\\', '/')
    normalized = normalized:gsub('/%./', '/')
    normalized = normalized:gsub('/+$', '')
    return normalized
end

---Normalizes an absolute path while resolving lexical dot segments.
---@param path string
---@return string
local function normalize_absolute(path)
    local normalized = path:gsub('\\', '/'):gsub('/+', '/')
    local prefix
    local remainder
    local drive = normalized:match('^([A-Za-z]:)/')
    if drive then
        prefix = drive:upper() .. '/'
        remainder = normalized:sub(4)
    elseif normalized:sub(1, 1) == '/' then
        prefix = '/'
        remainder = normalized:sub(2)
    else
        prefix = ''
        remainder = normalized
    end

    local segments = {}
    for segment in remainder:gmatch('[^/]+') do
        if segment == '..' then
            assert(#segments > 0,
                'path must not escape its absolute root: ' .. path)
            table.remove(segments)
        elseif segment ~= '.' and segment ~= '' then
            table.insert(segments, segment)
        end
    end
    local collapsed = prefix .. table.concat(segments, '/')
    if collapsed == '' and prefix ~= '' then return prefix end
    return collapsed
end

---Normalizes a file path against an absolute project root and enforces containment for relative paths.
---@param path string
---@param base_root string
---@param case_insensitive boolean|nil
---@return string, string
function M.normalize_file_path(path, base_root, case_insensitive)
    assert(type(path) == 'string' and path ~= '',
        'file path must be a nonempty string')
    assert(type(base_root) == 'string' and base_root ~= '',
        'file path base root must be a nonempty string')
    local relative = not M.is_absolute(path:gsub('\\', '/'))
    local candidate = relative and base_root .. '/' .. path or path
    candidate = normalize_absolute(candidate)
    assert(M.is_absolute(candidate),
        'normalized file path must be absolute: ' .. candidate)
    local normalized_base = normalize_absolute(base_root)
    local containment_path = candidate
    local containment_base = normalized_base
    if case_insensitive then
        containment_path = containment_path:lower()
        containment_base = containment_base:lower()
    end
    if relative then
        assert(containment_path:sub(1, #containment_base + 1) ==
            containment_base .. '/',
            'relative file path must remain beneath its project root')
    end
    local identity = case_insensitive and candidate:lower() or candidate
    return candidate, identity
end

return M
