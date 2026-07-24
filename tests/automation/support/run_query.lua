-- Reads retained automation run history, details, or captured logs.

local operation, run_id = ...

---Configures pure-Lua lookup and derives the DwarfSpec runtime root.
---@return string, string|nil
local function package_root()
    local source = debug.getinfo(1, 'S').source:gsub('^@', '')
    local lua_root = source:match(
        '^(.*)[/\\]dwarfspec[/\\]automation[/\\]run_query%.lua$')
    if lua_root then
        local separator = package.config:sub(1, 1)
        package.path = lua_root .. separator .. '?.lua;' .. lua_root ..
            separator .. '?' .. separator .. 'init.lua;' .. package.path
        return lua_root, lua_root
    end
    local root = assert(source:match(
        '^(.*)[/\\]tests[/\\]automation[/\\]support[/\\]' ..
            'run_query%.lua$'),
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
            separator .. 'automation' .. separator .. 'host.lua'))()
    end
    return assert(loadfile(root ..
        '/src/dwarfspec/automation/host.lua'))()
end

---Builds one read-only query response without creating service state.
---@param host table
---@return table
local function query(host)
    local loaded = dfhack.dwarfspec ~= nil
    if operation == 'history' then
        return {
            schema='dwarfspec.history.v1',
            protocol=2,
            service_loaded=loaded,
            service_instance_id=loaded and
                dfhack.dwarfspec.service_instance_id or nil,
            runs=loaded and host.run_history() or {},
        }
    end

    assert(operation == 'show' or operation == 'logs',
        'unsupported run query operation: ' .. tostring(operation))
    assert(type(run_id) == 'string' and run_id ~= '',
        'run id argument is required')
    local found = loaded and host.find(run_id) ~= nil
    if operation == 'show' then
        local response = {
            schema='dwarfspec.run-inspection.v1',
            protocol=2,
            service_loaded=loaded,
            found=found,
            run_id=run_id,
        }
        if found then
            local inspection = host.run_inspection(run_id)
            for name, value in pairs(inspection) do response[name] = value end
        end
        return response
    end

    local response = {
        schema='dwarfspec.run-logs.v1',
        protocol=2,
        service_loaded=loaded,
        found=found,
        run_id=run_id,
    }
    if found then
        local logs = host.run_logs(run_id)
        for name, value in pairs(logs) do response[name] = value end
    end
    return response
end

local root, lua_root = package_root()
local host = load_host(root, lua_root)
print('DWARFSPEC_JSON ' .. host.encode_transport(query(host)))
