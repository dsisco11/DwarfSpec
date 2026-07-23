-- Cancels one exact capability-owned queued automation run.

local run_id, owner_capability, after_sequence_text, reason = ...
assert(run_id, 'run id argument is required')
assert(owner_capability, 'owner capability argument is required')
local after_sequence = assert(tonumber(after_sequence_text),
    'event cursor argument must be numeric')

---Configures pure-Lua lookup and derives the DwarfSpec runtime root.
---@return string, string|nil
local function package_root()
    local source = debug.getinfo(1, 'S').source:gsub('^@', '')
    local lua_root = source:match(
        '^(.*)[/\\]dwarfspec[/\\]automation[/\\]cancel%.lua$')
    if lua_root then
        local separator = package.config:sub(1, 1)
        package.path = lua_root .. separator .. '?.lua;' .. lua_root ..
            separator .. '?' .. separator .. 'init.lua;' .. package.path
        return lua_root, lua_root
    end
    local root = assert(source:match(
        '^(.*)[/\\]tests[/\\]automation[/\\]support[/\\]cancel%.lua$'),
        'could not derive DwarfSpec root from ' .. source)
    package.path = root .. '/src/?.lua;' .. root ..
        '/src/?/init.lua;' .. package.path
    return root
end

---Loads the host from this installed package without stale cached modules.
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
        return assert(loadfile(root .. separator .. 'dwarfspec' ..
            separator .. 'automation' .. separator .. 'host.lua'))()
    end
    return assert(loadfile(root ..
        '/src/dwarfspec/automation/host.lua'))()
end

local root, lua_root = package_root()
local host = load_host(root, lua_root)
local run = host.cancel(run_id, owner_capability,
    reason or 'external runner cancellation')
local transport = host.transport(run.run_id, after_sequence)
print('DWARFSPEC_JSON ' .. host.encode_transport(transport))
