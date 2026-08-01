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

return M
