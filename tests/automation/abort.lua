-- Aborts one owned queued or suspended in-process automation run.

local run_id = assert(..., 'run id argument is required')

---Configures pure-Lua module lookup and derives the DwarfSpec runtime root.
---@return string, string|nil
local function package_root()
    local source = debug.getinfo(1, 'S').source:gsub('^@', '')
    local lua_root = source:match(
        '^(.*)[/\\]dwarfspec[/\\]automation[/\\]abort%.lua$')
    if lua_root then
        local separator = package.config:sub(1, 1)
        package.path = lua_root .. separator .. '?.lua;' .. lua_root ..
            separator .. '?' .. separator .. 'init.lua;' .. package.path
        return lua_root, lua_root
    end
    local root = source:match('^(.*)[/\\]tests[/\\]automation[/\\]abort%.lua$')
    root = assert(root, 'could not derive DwarfSpec root from ' .. source)
    package.path = root .. '/src/?.lua;' .. root ..
        '/src/?/init.lua;' .. package.path
    return root
end

---Loads the host from this installed package without reusing an older cache.
---@param root string
---@param lua_root string|nil
---@return table
local function load_host(root, lua_root)
    if lua_root then
        for name in pairs(package.loaded) do
            if name == 'dwarfspec.ds' or
                    name:match('^dwarfspec%.automation%.') then
                package.loaded[name] = nil
            end
        end
        local separator = package.config:sub(1, 1)
        return assert(loadfile(root .. separator .. 'dwarfspec' .. separator ..
            'automation' .. separator .. 'host.lua'))()
    end
    return assert(loadfile(root ..
        '/tests/automation/support/busted_host.lua'))()
end

local root, lua_root = package_root()
local host = load_host(root, lua_root)
local run = host.abort(run_id)
run.terminal_observed = true
print(('DWARFSPEC protocol=%d run_id=%s state=%s generation=%d')
    :format(run.protocol_version, run.run_id, run.state, run.generation))
print('DWARFSPEC_JSON ' .. host.encode_report(run))
