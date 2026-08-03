-- Production adapter that discards one retained terminal result.

local run_id, generation_text, after_sequence_text, reason = ...
assert(run_id, 'run id argument is required')
local generation = assert(tonumber(generation_text),
    'generation argument must be numeric')
local after_sequence = assert(tonumber(after_sequence_text),
    'event cursor argument must be numeric')

---Configures pure-Lua lookup and derives the DwarfSpec runtime root.
---@return string, string|nil
local function package_root()
    local source = debug.getinfo(1, 'S').source:gsub('^@', '')
    local lua_root = source:match(
        '^(.*)[/\\]dwarfspec[/\\]host[/\\]entrypoints[/\\]discard%.lua$')
    if lua_root then
        local separator = package.config:sub(1, 1)
        package.path = lua_root .. separator .. '?.lua;' .. lua_root ..
            separator .. '?' .. separator .. 'init.lua;' .. package.path
        return lua_root, lua_root
    end
    local root = assert(source:match(
        '^(.*)[/\\]tests[/\\]automation[/\\]support[/\\]discard%.lua$'),
        'could not derive DwarfSpec root from ' .. source)
    package.path = root .. '/src/?.lua;' .. root ..
        '/src/?/init.lua;' .. package.path
    return root
end

---Loads the host from this installed package.
---@param root string
---@param lua_root string|nil
---@return table
local function load_host(root, lua_root)
    if lua_root then
        local separator = package.config:sub(1, 1)
        return assert(loadfile(root .. separator .. 'dwarfspec' ..
            separator .. 'host' .. separator .. 'execution' .. separator .. 'host.lua'))()
    end
    return assert(loadfile(root ..
        '/src/dwarfspec/host/execution/host.lua'))()
end

local root, lua_root = package_root()
local host = load_host(root, lua_root)
local response = require('dwarfspec.host.entrypoints.operation_response')
response.execute(function()
    local run = host.discard(run_id, generation,
        reason or 'local operator discarded retained result')
    return host.transport(run.run_id, after_sequence)
end, function(transport)
    print('DWARFSPEC_JSON ' .. host.encode_transport(transport))
end, require('json').encode)
