-- External command project-root and live-spec discovery services.

local glob = require('dwarfspec.glob')

local M = {}

M.default_test_glob = '*.ds.lua'

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

---Resolves a project root from an explicit option or current directory.
---@param explicit_root string|nil
---@param current_directory string
---@param filesystem table
---@return string
function M.resolve_root(explicit_root, current_directory, filesystem)
    local root = explicit_root or current_directory
    assert(type(root) == 'string' and root ~= '',
        'project root must be a nonempty path')
    if explicit_root and not M.is_absolute(root) then
        root = M.join(current_directory, root)
    end
    root = M.normalize(root)
    assert(filesystem.isdir(root), 'project root is not a directory: ' .. root)
    return root
end

---Returns an external LuaFileSystem-backed filesystem surface.
---@return table
function M.filesystem()
    local lfs = require('lfs')
    return {
        isfile=function(path)
            return lfs.attributes(path, 'mode') == 'file'
        end,
        isdir=function(path)
            return lfs.attributes(path, 'mode') == 'directory'
        end,
        listdir=function(path)
            local entries = {}
            for entry in lfs.dir(path) do
                if entry ~= '.' and entry ~= '..' then
                    table.insert(entries, entry)
                end
            end
            return entries
        end,
        currentdir=lfs.currentdir,
        mkdir=lfs.mkdir,
    }
end

---Discovers stable project-relative canonical live-spec identities.
---@param project_root string
---@param filesystem table
---@param test_glob string|nil
---@return string[]
function M.discover(project_root, filesystem, test_glob)
    local tests_root = M.join(project_root, 'tests')
    assert(filesystem.isdir(tests_root),
        'project tests directory was not found: ' .. tests_root)
    test_glob = test_glob or M.default_test_glob
    local test_pattern = glob.compile(test_glob)
    local match_canonical_identity = test_glob:find('/', 1, true) ~= nil or
        test_glob:find('\\', 1, true) ~= nil
    local identities = {}

    ---Visits one test directory in stable lexical order.
    ---@param directory string
    ---@param relative_directory string
    local function visit(directory, relative_directory)
        local entries = filesystem.listdir(directory)
        table.sort(entries)
        for _, entry in ipairs(entries) do
            local relative = relative_directory == '' and entry or
                relative_directory .. '/' .. entry
            local path = M.join(directory, entry)
            if filesystem.isdir(path) then
                visit(path, relative)
            elseif filesystem.isfile(path) then
                local identity = 'tests/' .. relative
                local candidate = match_canonical_identity and identity or
                    entry
                if candidate:match(test_pattern) then
                    table.insert(identities, identity)
                end
            end
        end
    end

    visit(tests_root, '')
    return identities
end

---Removes the canonical tests prefix for the in-process host selector.
---@param identity string
---@return string
function M.host_spec(identity)
    local relative = identity:match('^tests/(.+)$')
    assert(relative, 'invalid canonical test identity: ' .. identity)
    return relative
end

---Creates a directory tree through a supplied filesystem surface.
---@param path string
---@param filesystem table
function M.mkdir_p(path, filesystem)
    path = M.normalize(path)
    if filesystem.isdir(path) then return end
    local parent = path:match('^(.*)/[^/]+$')
    if parent and parent ~= path and not filesystem.isdir(parent) then
        M.mkdir_p(parent, filesystem)
    end
    local ok, mkdir_error = filesystem.mkdir(path)
    assert(ok or filesystem.isdir(path),
        'could not create directory ' .. path .. ': ' .. tostring(mkdir_error))
end

return M
