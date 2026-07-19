-- Aborts one owned queued or suspended in-process automation run.

local run_id = assert(..., 'run id argument is required')

---Derives the repository root from this entry point's absolute source path.
---@return string
local function repository_root()
    local source = debug.getinfo(1, 'S').source:gsub('^@', '')
    local root = source:match('^(.*)[/\\]Tests[/\\]Automation[/\\]abort%.lua$')
    return assert(root, 'could not derive repository root from ' .. source)
end

local root = repository_root()
local host = assert(loadfile(root ..
    '/Tests/Automation/support/busted_host.lua'))()
local run = host.abort(run_id)
run.terminal_observed = true
print(('DWARFUI_AUTOMATION protocol=%d run_id=%s state=%s generation=%d')
    :format(run.protocol_version, run.run_id, run.state, run.generation))
print('DWARFUI_AUTOMATION_JSON ' .. host.encode_report(run))
