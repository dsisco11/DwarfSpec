-- Reports one active or retained in-process automation run.

local run_id, output_offset_text = ...
assert(run_id, 'run id argument is required')

---Derives the repository root from this entry point's absolute source path.
---@return string
local function repository_root()
    local source = debug.getinfo(1, 'S').source:gsub('^@', '')
    local root = source:match('^(.*)[/\\]tests[/\\]automation[/\\]status%.lua$')
    return assert(root, 'could not derive repository root from ' .. source)
end

---Escapes one status value onto a stable single output line.
---@param value any
---@return string
local function escape(value)
    return tostring(value):gsub('\\', '\\\\'):gsub('\r', '\\r')
        :gsub('\n', '\\n')
end

local root = repository_root()
local host = assert(loadfile(root ..
    '/tests/automation/support/busted_host.lua'))()
local poll_ok, run = pcall(host.poll, run_id)
if not poll_ok then qerror(run) end

print(('DWARFUI_AUTOMATION protocol=%d run_id=%s state=%s generation=%d ' ..
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
print('DWARFUI_AUTOMATION_JSON ' .. host.encode_report(run))
