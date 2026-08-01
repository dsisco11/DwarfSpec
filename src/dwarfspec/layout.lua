-- Resolves source-tree and installed DwarfSpec runtime locations.

local M = {}

local host_script_names = {
    'bootstrap',
    'status',
    'recover',
    'recover_executor',
    'scheduler_status',
    'run_query',
    'abort',
    'acknowledge',
    'probe',
    'cancel',
    'discard',
    'event_read',
}

---Returns whether one path names a readable file.
---@param path string
---@return boolean
local function is_file(path)
    local file = io.open(path, 'rb')
    if not file then return false end
    file:close()
    return true
end

---Returns the active platform path separator.
---@return string
local function separator()
    return package.config:sub(1, 1)
end

---Joins path fragments with the active platform separator.
---@param root string
---@param relative_path string
---@return string
local function join(root, relative_path)
    return root .. separator() .. relative_path:gsub('[/\\]', separator())
end

---Builds the direct DFHack entry-script paths beneath one package root.
---@param package_root string
---@param namespace_root string
---@return table<string, string>
local function host_scripts(package_root, namespace_root)
    local scripts = {}
    for _, name in ipairs(host_script_names) do
        scripts[name] = join(package_root,
            namespace_root .. '/' .. name .. '.lua')
    end
    return scripts
end

---Derives the Lua module root containing the installed dwarfspec namespace.
---@return string
function M.lua_root()
    local source = debug.getinfo(1, 'S').source:gsub('^@', '')
    local root = source:match('^(.*)[/\\]dwarfspec[/\\]layout%.lua$')
    return assert(root, 'could not derive DwarfSpec Lua module root')
end

---Builds paths for either the source tree or an installed LuaRocks tree.
---@return table
function M.current()
    local lua_root = M.lua_root()
    local package_root, source_suffix_count = lua_root:gsub(
        '[/\\]src$', '')

    if source_suffix_count == 1 then
        return {
            package_root=package_root,
            host_scripts=host_scripts(package_root,
                'src/dwarfspec/automation'),
        }
    end

    local installed_bootstrap = join(lua_root,
        'dwarfspec/automation/bootstrap.lua')
    if is_file(installed_bootstrap) then
        return {
            package_root=lua_root,
            host_scripts=host_scripts(lua_root, 'dwarfspec/automation'),
        }
    end

    error(('DwarfSpec package layout is incomplete under %s.'):format(
        lua_root))
end

return M
