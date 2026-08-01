-- Pinned and project-local Lua module environment management.

local M = {}

---Returns a platform-correct joined path.
---@param root string
---@param relative_path string
---@return string
local function join_path(root, relative_path)
    local separator = package.config:sub(1, 1)
    return root .. separator .. relative_path:gsub('[/\\]', separator)
end

---Creates one module-environment service with explicit runtime dependencies.
---@param dependencies table
---@return table
function M.new(dependencies)
    local function contains(search_path, entry)
        for candidate in search_path:gmatch('[^;]+') do
            if candidate == entry then return true end
        end
        return false
    end
    local function is_file(path)
        local file = io.open(path, 'rb')
        if not file then return false end
        file:close()
        return true
    end
    local function lua_root(package_root)
        if is_file(join_path(package_root, 'busted/core.lua')) then return package_root end
        local version = assert(_VERSION:match('Lua (%d+%.%d+)'),
            'could not determine the active Lua version from ' .. tostring(_VERSION))
        return join_path(package_root, '.luarocks/share/lua/' .. version)
    end
    return {
        ---Configures pinned dependencies and native adapters.
        configure=function(package_root, configured_root)
            local separator = package.config:sub(1, 1)
            local root = configured_root or lua_root(package_root)
            local entries = {root .. separator .. '?.lua', root .. separator .. '?' .. separator .. 'init.lua'}
            for index = #entries, 1, -1 do
                if not contains(package.path, entries[index]) then package.path = entries[index] .. ';' .. package.path end
            end
            dependencies.clear_dependencies()
            local system = dependencies.load_module(package_root, 'dwarfspec.host.environment.system_adapter')
            local lfs = dependencies.load_module(package_root, 'dwarfspec.host.environment.lfs_adapter')
            package.preload.system, package.preload.lfs = function() return system end, function() return lfs end
            package.loaded.system, package.loaded.lfs = system, lfs
            return entries
        end,
        ---Installs project lookup and returns idempotent cleanup plus its audit.
        configure_project=function(project_root, protected_entries, runtime_package)
            assert(type(project_root) == 'string' and project_root ~= '', 'project root must be a nonempty string')
            assert(type(protected_entries) == 'table', 'protected package paths must be a table')
            runtime_package = runtime_package or package
            assert(type(runtime_package.path) == 'string' and type(runtime_package.loaded) == 'table' and type(runtime_package.searchpath) == 'function', 'runtime package must provide path, loaded, and searchpath')
            local separator = package.config:sub(1, 1)
            local project_entries = {project_root .. separator .. '?.lua', project_root .. separator .. '?' .. separator .. 'init.lua'}
            local original_path, before = runtime_package.path, {}
            for name in pairs(runtime_package.loaded) do before[name] = true end
            local ordered, included = {}, {}
            local function include(entry) if entry ~= '' and not included[entry] then table.insert(ordered, entry); included[entry] = true end end
            for _, entry in ipairs(protected_entries) do include(entry) end
            for _, entry in ipairs(project_entries) do include(entry) end
            for entry in original_path:gmatch('[^;]+') do include(entry) end
            runtime_package.path = table.concat(ordered, ';')
            local audit = {original_path=original_path, project_entries=project_entries, restored=false, path_restored=false, evicted_modules={}}
            local restored = false
            return function()
                if restored then return end
                restored = true
                local project_path, protected_path = table.concat(project_entries, ';'), table.concat(protected_entries, ';')
                for name in pairs(runtime_package.loaded) do
                    if type(name) == 'string' and not before[name] and runtime_package.searchpath(name, project_path) and not runtime_package.searchpath(name, protected_path) then
                        runtime_package.loaded[name] = nil; table.insert(audit.evicted_modules, name)
                    end
                end
                runtime_package.path = original_path; audit.restored = true; audit.path_restored = runtime_package.path == original_path; table.sort(audit.evicted_modules)
            end, audit
        end,
    }
end

return M
