-- Resolves source-tree and installed DwarfSpec runtime locations.

local M = {}

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
            host_scripts={
                bootstrap=join(package_root,
                    'src/dwarfspec/automation/bootstrap.lua'),
                status=join(package_root,
                    'src/dwarfspec/automation/status.lua'),
                recover=join(package_root,
                    'src/dwarfspec/automation/recover.lua'),
                recover_executor=join(package_root,
                    'src/dwarfspec/automation/recover_executor.lua'),
                scheduler_status=join(package_root,
                    'src/dwarfspec/automation/scheduler_status.lua'),
                run_query=join(package_root,
                    'src/dwarfspec/automation/run_query.lua'),
                abort=join(package_root,
                    'src/dwarfspec/automation/abort.lua'),
                acknowledge=join(package_root,
                    'src/dwarfspec/automation/acknowledge.lua'),
                probe=join(package_root,
                    'src/dwarfspec/automation/probe.lua'),
            },
        }
    end

    local installed_bootstrap = join(lua_root,
        'dwarfspec/automation/bootstrap.lua')
    if is_file(installed_bootstrap) then
        return {
            package_root=lua_root,
            host_scripts={
                bootstrap=installed_bootstrap,
                status=join(lua_root, 'dwarfspec/automation/status.lua'),
                recover=join(lua_root, 'dwarfspec/automation/recover.lua'),
                recover_executor=join(lua_root,
                    'dwarfspec/automation/recover_executor.lua'),
                scheduler_status=join(lua_root,
                    'dwarfspec/automation/scheduler_status.lua'),
                run_query=join(lua_root,
                    'dwarfspec/automation/run_query.lua'),
                abort=join(lua_root, 'dwarfspec/automation/abort.lua'),
                acknowledge=join(lua_root,
                    'dwarfspec/automation/acknowledge.lua'),
                probe=join(lua_root, 'dwarfspec/automation/probe.lua'),
            },
        }
    end

    error(('DwarfSpec package layout is incomplete under %s.'):format(
        lua_root))
end

return M
