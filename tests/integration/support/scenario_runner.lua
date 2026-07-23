-- Runs one real CLI scenario with a controlled interruption or corruption.

local mode, root, project_root, result_path, run_id = ...
assert(mode == 'interrupt' or mode == 'transport',
    'scenario mode must be interrupt or transport')
assert(root and project_root and result_path and run_id,
    'scenario runner requires root, project, result, and run identifiers')

package.path = root .. '/src/?.lua;' .. root ..
    '/src/?/init.lua;' .. root .. '/.luarocks/share/lua/5.4/?.lua;' ..
    root .. '/.luarocks/share/lua/5.4/?/init.lua;' .. package.path
package.cpath = root .. '/.luarocks/lib/lua/5.4/?.dll;' .. package.cpath

local cli = require('dwarfspec.cli')
local process = require('dwarfspec.process')
local reports = require('dwarfspec.report')
local system = require('system')

local active_seen = false
local injected = false

---Invokes the real bridge and optionally corrupts one active status response.
---@param executable string
---@param arguments string[]
---@return table
local function invoke(executable, arguments)
    local result = process.invoke(executable, arguments)
    if arguments[3]:match('status%.lua$') and result.exit_code == 0 then
        local ok, transport = pcall(reports.parse_transport, result.lines, {
            run_id=run_id,
            after_sequence=tonumber(arguments[6]) or 0,
        })
        if ok and transport.snapshot.activated_at_ms ~= nil then
            active_seen = true
            if mode == 'transport' and not injected then
                injected = true
                result.lines = {'deliberately malformed integration transport'}
            end
        end
    end
    return result
end

---Sleeps normally until the active interruption injection point.
---@param seconds number
local function sleep(seconds)
    if mode == 'interrupt' and active_seen and not injected then
        injected = true
        error('interrupted by multi-project integration harness')
    end
    system.sleep(seconds)
end

local exit_code = cli.main({
    'run',
    '--project-root=' .. project_root,
    '--test-glob=tests/live/timeout_spec.ds.lua',
    '--run-id=' .. run_id,
    '--results=' .. result_path,
    '--timeout=10',
    '--poll-interval-ms=25',
}, {
    package_root=root,
    current_directory=project_root,
    invoke=invoke,
    sleep=sleep,
    now=system.monotime,
    system=system,
})

os.exit(exit_code)
