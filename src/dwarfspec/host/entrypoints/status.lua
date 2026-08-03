-- Production adapter that polls a run through cursor-based transport.

local run_id, owner_capability, after_sequence_text, generation_text = ...
assert(run_id, 'run id argument is required')
assert(owner_capability, 'owner capability argument is required')
local after_sequence = assert(tonumber(after_sequence_text),
    'event cursor argument must be numeric')
local generation = generation_text and assert(tonumber(generation_text),
    'generation argument must be numeric') or nil

---Configures pure-Lua module lookup and derives the DwarfSpec runtime root.
---@return string, string|nil
local function package_root()
    local source = debug.getinfo(1, 'S').source:gsub('^@', '')
    local lua_root = source:match(
        '^(.*)[/\\]dwarfspec[/\\]host[/\\]entrypoints[/\\]status%.lua$')
    if lua_root then
        local separator = package.config:sub(1, 1)
        package.path = lua_root .. separator .. '?.lua;' .. lua_root ..
            separator .. '?' .. separator .. 'init.lua;' .. package.path
        return lua_root, lua_root
    end
    local root = source:match(
        '^(.*)[/\\]tests[/\\]automation[/\\]support[/\\]status%.lua$')
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
                    name:match('^dwarfspec%.host%.') then
                package.loaded[name] = nil
            end
        end
        local separator = package.config:sub(1, 1)
        return assert(loadfile(root .. separator .. 'dwarfspec' .. separator ..
            'host' .. separator .. 'execution' .. separator .. 'host.lua'))()
    end
    return assert(loadfile(root ..
        '/src/dwarfspec/host/execution/host.lua'))()
end

local root, lua_root = package_root()
local host = load_host(root, lua_root)
local response = require('dwarfspec.host.entrypoints.operation_response')
response.execute(function()
    return host.poll_transport(run_id, owner_capability, after_sequence,
        generation)
end, function(transport)
    print(('DWARFSPEC protocol=%d run_id=%s state=%s generation=%d')
        :format(transport.protocol, transport.run_id,
            transport.snapshot.state, transport.generation))
    print('DWARFSPEC_JSON ' .. host.encode_transport(transport))
end, require('json').encode)
