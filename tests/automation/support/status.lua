-- Reports one active or retained in-process automation run.

local run_id, owner_capability, output_offset_text = ...
assert(run_id, 'run id argument is required')
assert(owner_capability, 'owner capability argument is required')

---Configures pure-Lua module lookup and derives the DwarfSpec runtime root.
---@return string, string|nil
local function package_root()
    local source = debug.getinfo(1, 'S').source:gsub('^@', '')
    local lua_root = source:match(
        '^(.*)[/\\]dwarfspec[/\\]automation[/\\]status%.lua$')
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
                    name:match('^dwarfspec%.automation%.') then
                package.loaded[name] = nil
            end
        end
        local separator = package.config:sub(1, 1)
        return assert(loadfile(root .. separator .. 'dwarfspec' .. separator ..
            'automation' .. separator .. 'host.lua'))()
    end
    return assert(loadfile(root ..
        '/src/dwarfspec/automation/host.lua'))()
end

---Escapes one status value onto a stable single output line.
---@param value any
---@return string
local function escape(value)
    return tostring(value):gsub('\\', '\\\\'):gsub('\r', '\\r')
        :gsub('\n', '\\n')
end

local root, lua_root = package_root()
local host = load_host(root, lua_root)
local poll_ok, run = pcall(host.poll, run_id, owner_capability)
if not poll_ok then qerror(run) end

print(('DWARFSPEC protocol=%d run_id=%s state=%s generation=%d ' ..
    'successes=%d failures=%d errors=%d pending=%d ' ..
    'total_successes=%d total_failures=%d total_errors=%d total_pending=%d ' ..
    'output_count=%d cleanup_confirmed=%s')
    :format(run.protocol_version, run.run_id, run.state, run.generation,
        run.counts.successes, run.counts.failures, run.counts.errors,
        run.counts.pending, run.totals.successes, run.totals.failures,
        run.totals.errors, run.totals.pending, #run.output_lines,
        tostring(run.cleanup_confirmed)))

local output_offset = tonumber(output_offset_text) or #run.output_lines
for index = output_offset + 1, #run.output_lines do
    print(('OUTPUT %d %s'):format(index, escape(run.output_lines[index])))
end
if host.is_terminal(run) then
    for index, detail in ipairs(run.failure_details) do
        print(('DETAIL %d kind=%s name=%s message=%s trace=%s'):format(
            index, escape(detail.kind), escape(detail.name),
            escape(detail.message), escape(detail.trace or '')))
    end
    if run.host_error then
        print('HOST_ERROR ' .. escape(run.host_error))
        print('HOST_TRACE ' .. escape(run.host_trace or ''))
    end
end
print('DWARFSPEC_JSON ' .. host.encode_report(run))
