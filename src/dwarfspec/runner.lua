-- External DwarfSpec orchestration over the supported dfhack-run bridge.

local process = require('dwarfspec.process')
local project = require('dwarfspec.project')
local reports = require('dwarfspec.report')

local M = {}

local EXIT = {
    success=0,
    usage=2,
    dependency=3,
    connection=4,
    host=5,
    test=6,
    timeout=7,
    aborted=8,
}

M.exit_codes = EXIT

---Creates one classified runner failure.
---@param kind string
---@param message string
---@return table
local function failure(kind, message)
    return {
        kind=kind,
        message=message,
        exit_code=assert(EXIT[kind], 'unknown runner failure kind: ' .. kind),
    }
end

---Raises one classified runner failure.
---@param kind string
---@param message string
local function fail(kind, message)
    error(failure(kind, message), 0)
end

---Removes an incidental Lua source location from a user-facing error.
---@param value any
---@return string
local function clean_message(value)
    return tostring(value):gsub('^.-:%d+: ', '')
end

---Returns whether a file can be opened for reading.
---@param path string
---@return boolean
local function is_file(path)
    local file = io.open(path, 'rb')
    if not file then return false end
    file:close()
    return true
end

---Returns one installed or source-tree host entry script path.
---@param options table
---@param name string
---@return string
local function host_script(options, name)
    local scripts = options.host_scripts or {}
    if scripts[name] then return scripts[name] end
    return project.join(options.package_root, 'tests/automation/' .. name ..
        '.lua')
end

---Resolves the shared Lua module root for source and installed layouts.
---@param package_root string
---@return string
local function lua_module_root(package_root)
    if is_file(project.join(package_root, 'busted/core.lua')) then
        return package_root
    end
    local lua_version = assert(_VERSION:match('Lua (%d+%.%d+)'),
        'could not determine the active Lua version from ' .. tostring(_VERSION))
    return project.join(package_root,
        '.luarocks/share/lua/' .. lua_version)
end

---Validates pure-Lua dependencies required by the in-process host.
---@param options table
local function validate_dependencies(options)
    local lua_root = lua_module_root(options.package_root)
    for _, path in ipairs({
            project.join(lua_root, 'busted/core.lua'),
            project.join(lua_root, 'busted/init.lua'),
            project.join(lua_root, 'luassert/init.lua'),
            host_script(options, 'bootstrap'),
            host_script(options, 'status'),
            host_script(options, 'abort'),
            host_script(options, 'probe')}) do
        if not is_file(path) then
            fail('dependency', 'DwarfSpec dependency was not found: ' .. path)
        end
    end
end

---Appends one repeated bootstrap option for every caller value.
---@param arguments string[]
---@param name string
---@param values string[]|nil
local function append_values(arguments, name, values)
    for _, value in ipairs(values or {}) do
        table.insert(arguments, '--' .. name .. '=' .. value)
    end
end

---Builds in-process bootstrap arguments for one selected run.
---@param options table
---@param run_id string
---@return string[]
local function bootstrap_arguments(options, run_id)
    local arguments = {
        'lua', '-f', host_script(options, 'bootstrap'),
        run_id,
        '--project-root=' .. options.project_root,
        '--repeat=' .. tostring(options.repeat_count),
        '--defer-frames=' .. tostring(options.startup_delay_frames),
        '--lease-timeout-ms=' .. tostring(options.lease_timeout_ms),
        '--lease-check-frames=' .. tostring(options.lease_check_frames),
        '--test-glob=' .. tostring(options.test_glob or '*.ds.lua'),
    }
    append_values(arguments, 'filter', options.filters)
    append_values(arguments, 'filter-out', options.filter_out)
    append_values(arguments, 'name', options.names)
    append_values(arguments, 'tag', options.tags)
    append_values(arguments, 'exclude-tag', options.exclude_tags)
    for _, identity in ipairs(options.identities) do
        table.insert(arguments, '--spec=' .. project.host_spec(identity))
    end
    return arguments
end

---Verifies a healthy DFHack core context before starting a run.
---@param runner string
---@param options table
---@param invoke function
local function verify_connection(runner, options, invoke)
    local ok, result = pcall(invoke, runner, {
        'lua', '-f', host_script(options, 'probe'),
    })
    if not ok then
        fail('connection', 'could not contact DFHack through ' .. runner ..
            ': ' .. clean_message(result))
    end
    if result.exit_code ~= 0 or
            result.lines[#result.lines] ~=
                'DWARFSPEC_PROBE protocol=1 core=true timeout=function' then
        fail('connection', 'DFHack is not running or did not provide a ' ..
            'healthy core Lua context')
    end
end

---Returns an externally unique and host-safe run identifier.
---@param now number
---@return string
local function generate_run_id(now)
    local random = math.random(0, 0x7fffffff)
    return ('dwarfspec-%d-%08x'):format(math.floor(now * 1000), random)
end

---Streams newly reported Busted progress through the caller callback.
---@param lines string[]
---@param emit function
local function emit_progress(lines, emit)
    for _, line in ipairs(reports.progress(lines)) do emit(line) end
end

---Writes the final DFHack-encoded run report when persistence is enabled.
---@param options table
---@param run_id string
---@param native_json string|nil
local function write_result(options, run_id, native_json)
    if options.result_directory == false then return end
    if not native_json then return end
    local filesystem = options.filesystem or project.filesystem()
    local directory = options.result_directory
    if not project.is_absolute(directory) then
        directory = project.join(options.project_root, directory)
    end
    project.mkdir_p(directory, filesystem)
    reports.write(project.join(directory, run_id .. '.json'), native_json)
end

---Attempts recovery abort without replacing the original runner failure.
---@param runner string
---@param options table
---@param run_id string
---@param invoke function
---@return table|nil, string|nil, string|nil
local function recovery_abort(runner, options, run_id, invoke)
    local result = invoke(runner, {
        'lua', '-f', host_script(options, 'abort'), run_id,
    })
    if result.exit_code ~= 0 then
        return nil, 'recovery abort exited with ' .. result.exit_code, nil
    end
    local ok, report, payload = pcall(reports.parse, result.lines, run_id,
        options.decode_json)
    if not ok then return nil, tostring(report), nil end
    if report.state ~= 'aborted' or not report.cleanup_confirmed then
        return report, 'recovery abort did not confirm cleanup', payload
    end
    return report, nil, payload
end

---Runs selected live specifications and returns a stable command outcome.
---@param options table
---@return table
function M.run(options)
    local system = options.system or require('system')
    local invoke = options.invoke or process.invoke
    local emit = options.emit or print
    local now = options.now or system.monotime
    local sleep = options.sleep or system.sleep
    local started_at = now()
    local run_id = options.run_id or generate_run_id(started_at)
    local runner
    local native_report
    local native_json
    local runner_error
    local bootstrap_attempted = false

    local ok, caught = xpcall(function()
        validate_dependencies(options)
        local resolved, resolve_error
        resolved, runner = pcall(process.resolve_runner, options,
            options.environment)
        if not resolved then
            resolve_error = runner
            runner = nil
            fail('dependency', clean_message(resolve_error))
        end
        if options.verbose then emit('DFHack runner: ' .. runner) end
        verify_connection(runner, options, invoke)

        bootstrap_attempted = true
        local start = invoke(runner, bootstrap_arguments(options, run_id))
        if start.exit_code ~= 0 then
            fail('host', 'DwarfSpec bootstrap exited with ' .. start.exit_code)
        end
        native_report, native_json = reports.parse(start.lines, run_id,
            options.decode_json)
        local output_offset = native_report.output_count
        emit_progress(start.lines, emit)

        while not native_report.terminal do
            if now() - started_at >= options.timeout_seconds then
                fail('timeout', ('DwarfSpec run timed out after %s seconds')
                    :format(options.timeout_seconds))
            end
            sleep(options.poll_interval_ms / 1000)
            local status = invoke(runner, {
                'lua', '-f', host_script(options, 'status'),
                run_id, tostring(output_offset),
            })
            if status.exit_code ~= 0 then
                fail('host', 'DwarfSpec status exited with ' ..
                    status.exit_code)
            end
            native_report, native_json = reports.parse(status.lines, run_id,
                options.decode_json)
            emit_progress(status.lines, emit)
            output_offset = native_report.output_count
        end

        if native_report.state == 'aborted' then
            fail('aborted', 'DwarfSpec run was aborted')
        end
        if native_report.state ~= 'passed' then
            fail('test', 'DwarfSpec run finished with state ' ..
                tostring(native_report.state))
        end
        if not native_report.cleanup_confirmed then
            fail('test', 'DwarfSpec run passed without confirmed cleanup')
        end
    end, function(value) return value end)

    if not ok then
        if type(caught) == 'table' and caught.exit_code then
            runner_error = caught
        elseif clean_message(caught):lower():match('interrupt') then
            runner_error = failure('aborted', 'DwarfSpec run interrupted')
        else
            runner_error = failure('host', clean_message(caught))
        end
        if runner and bootstrap_attempted and
                (not native_report or not native_report.terminal) then
            local aborted, abort_error, abort_json = recovery_abort(runner, options,
                run_id, invoke)
            if aborted then
                native_report = aborted
                native_json = abort_json
            end
            if abort_error then
                runner_error.message = runner_error.message ..
                    '; recovery failed: ' .. abort_error
            end
        end
    end

    local write_ok, write_error = pcall(write_result, options, run_id,
        native_json)
    if not write_ok and not runner_error then
        runner_error = failure('host', tostring(write_error))
    elseif not write_ok then
        runner_error.message = runner_error.message ..
            '; could not write result report: ' .. tostring(write_error)
    end

    return {
        exit_code=runner_error and runner_error.exit_code or EXIT.success,
        run_id=run_id,
        runner=runner,
        report=native_report,
        error=runner_error,
    }
end

---Explicitly aborts one active run and requires confirmed cleanup.
---@param options table
---@param run_id string
---@return table
function M.abort(options, run_id)
    local invoke = options.invoke or process.invoke
    local ok, runner = pcall(process.resolve_runner, options,
        options.environment)
    if not ok then
        return {exit_code=EXIT.dependency,
            error=failure('dependency', clean_message(runner))}
    end
    if options.verbose and options.emit then
        options.emit('DFHack runner: ' .. runner)
    end
    local connected, connection_error = pcall(verify_connection, runner,
        options, invoke)
    if not connected then
        local detail = type(connection_error) == 'table' and
            connection_error or
            failure('connection', clean_message(connection_error))
        return {exit_code=detail.exit_code, error=detail}
    end
    local result = invoke(runner, {
        'lua', '-f', host_script(options, 'abort'), run_id,
    })
    if result.exit_code ~= 0 then
        return {exit_code=EXIT.host,
            error=failure('host', 'DwarfSpec abort exited with ' ..
                result.exit_code)}
    end
    local ok, report = pcall(reports.parse, result.lines, run_id,
        options.decode_json)
    if not ok then
        return {exit_code=EXIT.host,
            error=failure('host', tostring(report))}
    end
    if report.state ~= 'aborted' or not report.cleanup_confirmed then
        return {exit_code=EXIT.test, report=report,
            error=failure('test', 'abort did not confirm cleanup')}
    end
    return {exit_code=EXIT.success, report=report}
end

return M
