-- Aborts one owned queued or suspended in-process automation run.

local run_id = assert(..., 'run id argument is required')

---Configures pure-Lua module lookup and derives the DwarfSpec runtime root.
---@return string
local function package_root()
    local source = debug.getinfo(1, 'S').source:gsub('^@', '')
    local lua_root = source:match(
        '^(.*)[/\\]dwarfspec[/\\]automation[/\\]abort%.lua$')
    if lua_root then
        local separator = package.config:sub(1, 1)
        package.path = lua_root .. separator .. '?.lua;' .. lua_root ..
            separator .. '?' .. separator .. 'init.lua;' .. package.path
        return lua_root
    end
    local root = source:match('^(.*)[/\\]tests[/\\]automation[/\\]abort%.lua$')
    root = assert(root, 'could not derive DwarfSpec root from ' .. source)
    package.path = root .. '/src/?.lua;' .. root ..
        '/src/?/init.lua;' .. package.path
    return root
end

local root = package_root()
local host_ok, host = pcall(require, 'dwarfspec.automation.host')
if not host_ok then
    host = assert(loadfile(root ..
        '/tests/automation/support/busted_host.lua'))()
end
local run = host.abort(run_id)
run.terminal_observed = true
print(('DWARFSPEC protocol=%d run_id=%s state=%s generation=%d')
    :format(run.protocol_version, run.run_id, run.state, run.generation))
print('DWARFSPEC_JSON ' .. host.encode_report(run))
