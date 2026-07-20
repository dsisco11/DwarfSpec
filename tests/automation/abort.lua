-- Aborts one owned queued or suspended in-process automation run.

local run_id = assert(..., 'run id argument is required')

---Derives the DwarfSpec package root from this entry point's source path.
---@return string
local function package_root()
    local source = debug.getinfo(1, 'S').source:gsub('^@', '')
    local root = source:match('^(.*)[/\\]tests[/\\]automation[/\\]abort%.lua$')
    return assert(root, 'could not derive repository root from ' .. source)
end

local root = package_root()
local host = assert(loadfile(root ..
    '/tests/automation/support/busted_host.lua'))()
local run = host.abort(run_id)
run.terminal_observed = true
print(('DWARFSPEC protocol=%d run_id=%s state=%s generation=%d')
    :format(run.protocol_version, run.run_id, run.state, run.generation))
print('DWARFSPEC_JSON ' .. host.encode_report(run))
