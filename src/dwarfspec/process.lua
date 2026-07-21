-- Cross-platform shell quoting and synchronous child-process invocation.

local M = {}

---Returns whether the selected platform uses Windows command quoting.
---@param platform string|nil
---@return boolean
function M.is_windows(platform)
    if platform then return platform == 'windows' end
    return package.config:sub(1, 1) == '\\'
end

---Quotes one argument for the selected command shell.
---@param argument any
---@param platform string|nil
---@return string
function M.quote(argument, platform)
    local value = tostring(argument)
    if M.is_windows(platform) then
        return '"' .. value:gsub('(\\*)"', '%1%1\\"')
            :gsub('(\\+)$', '%1%1') .. '"'
    end
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

---Builds one shell command with stderr redirected into stdout.
---@param executable string
---@param arguments string[]
---@param platform string|nil
---@return string
function M.command(executable, arguments, platform)
    local parts = {M.quote(executable, platform)}
    for _, argument in ipairs(arguments) do
        table.insert(parts, M.quote(argument, platform))
    end
    table.insert(parts, '2>&1')
    local command = table.concat(parts, ' ')
    if M.is_windows(platform) then return '"' .. command .. '"' end
    return command
end

---Invokes one process and returns its output lines and normalized exit code.
---@param executable string
---@param arguments string[]
---@param options table|nil
---@return table
function M.invoke(executable, arguments, options)
    options = options or {}
    local command = M.command(executable, arguments, options.platform)
    local pipe, open_error = (options.popen or io.popen)(command, 'r')
    assert(pipe, 'could not start process: ' .. tostring(open_error))
    local lines = {}
    for line in pipe:lines() do table.insert(lines, line) end
    local ok, reason, code = pipe:close()
    local exit_code = 0
    if ok ~= true then
        if type(code) == 'number' then
            exit_code = code
        elseif type(ok) == 'number' then
            exit_code = ok
        else
            exit_code = 1
        end
    end
    return {
        command=command,
        lines=lines,
        exit_code=exit_code,
        reason=reason,
    }
end

---Returns whether one candidate path names a readable file.
---@param path string
---@return boolean
local function is_file(path)
    local file = io.open(path, 'rb')
    if not file then return false end
    file:close()
    return true
end

---Resolves dfhack-run through options, environment, or the process PATH.
---@param options table
---@param environment table|nil
---@return string
function M.resolve_runner(options, environment)
    environment = environment or {
        getenv=os.getenv,
    }
    local file_exists = options.isfile or is_file
    local explicit = options.runner or environment.getenv('DFHACK_RUNNER')
    if explicit and explicit ~= '' then
        assert(file_exists(explicit),
            'configured DFHack runner was not found: ' .. explicit)
        return explicit
    end

    local dfhack_root = environment.getenv('DFHACK_ROOT')
    if dfhack_root and dfhack_root ~= '' then
        local separator = M.is_windows(options.platform) and '\\' or '/'
        local names = M.is_windows(options.platform) and
            {'dfhack-run.exe', 'dfhack-run'} or {'dfhack-run', 'dfhack-run.exe'}
        for _, name in ipairs(names) do
            local candidate = dfhack_root .. separator .. name
            if file_exists(candidate) then return candidate end
        end
        error('DFHACK_ROOT does not contain dfhack-run: ' .. dfhack_root, 2)
    end

    local path = environment.getenv('PATH') or ''
    local path_separator = M.is_windows(options.platform) and ';' or ':'
    local directory_separator = M.is_windows(options.platform) and '\\' or '/'
    local names = M.is_windows(options.platform) and
        {'dfhack-run.exe', 'dfhack-run'} or {'dfhack-run', 'dfhack-run.exe'}
    for directory in (path .. path_separator):gmatch(
            '(.-)' .. (path_separator == ';' and ';' or ':')) do
        if directory ~= '' then
            directory = directory:gsub('^"(.*)"$', '%1')
            for _, name in ipairs(names) do
                local candidate = directory .. directory_separator .. name
                if file_exists(candidate) then return candidate end
            end
        end
    end
    error('could not find dfhack-run; set DFHACK_RUNNER, set DFHACK_ROOT, ' ..
        'or add dfhack-run to PATH', 2)
end

return M
