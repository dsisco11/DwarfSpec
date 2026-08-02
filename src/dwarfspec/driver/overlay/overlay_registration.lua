-- Driver-owned staging workflow for real overlay registration tests.

local M = {}

---Runs one cleanup operation while retaining failures for later aggregation.
---@param failures string[]
---@param name string
---@param action function
local function attempt(failures, name, action)
    local ok, failure = xpcall(action, debug.traceback)
    if not ok then
        table.insert(failures, name .. ': ' .. tostring(failure))
    end
end

---Returns whether the configuration artifact exactly matches its snapshot.
---@param services table
---@param existed boolean
---@param contents string|nil
---@return boolean
local function config_matches(services, existed, contents)
    if existed ~= services.isfile(services.config_path) then return false end
    return not existed or services.read_file(services.config_path) == contents
end

---Returns a cleanup verification result without replacing prior failures.
---@param check function
---@return boolean
local function safe_check(check)
    local ok, result = pcall(check)
    return ok and not not result
end

---Restores every external artifact owned by one staged registration script.
---@param staged table
---@param services table
---@param source_contents string
---@param config_existed boolean
---@param config_contents string|nil
local function restore(staged, services, source_contents, config_existed,
        config_contents)
    if staged.cleanup_state.complete then return end
    local failures = {}
    local names = {}
    attempt(failures, 'enumerate staged overlays', function()
        names = services.registered_names(staged.script_name)
    end)
    for _, name in ipairs(names) do
        attempt(failures, 'disable ' .. name, function()
            if services.is_enabled(name) then services.disable(name) end
        end)
    end
    attempt(failures, 'remove staged script', function()
        if not services.isfile(staged.path) then return end
        assert(services.read_file(staged.path) == source_contents,
            'refusing to remove a modified overlay registration script: ' ..
                staged.path)
        local removed, remove_error = services.remove_file(staged.path)
        assert(removed ~= false and removed ~= nil, remove_error)
    end)
    attempt(failures, 'restore overlay configuration', function()
        if config_existed then
            services.write_file(services.config_path, config_contents)
        elseif services.isfile(services.config_path) then
            local removed, remove_error =
                services.remove_file(services.config_path)
            assert(removed ~= false and removed ~= nil, remove_error)
        end
    end)
    attempt(failures, 'final overlay rescan', services.rescan)
    attempt(failures, 'verify staged script removal', function()
        assert(not services.isfile(staged.path),
            'staged overlay registration script still exists: ' ..
                staged.path)
    end)
    attempt(failures, 'verify overlay configuration restoration', function()
        assert(config_matches(services, config_existed, config_contents),
            'overlay configuration was not restored exactly')
    end)
    attempt(failures, 'verify registration removal', function()
        assert(#services.registered_names(staged.script_name) == 0,
            'staged overlay registrations remain after cleanup')
    end)
    local script_removed = safe_check(function()
        return not services.isfile(staged.path)
    end)
    local config_restored = safe_check(function()
        return config_matches(services, config_existed, config_contents)
    end)
    local registrations_removed = safe_check(function()
        return #services.registered_names(staged.script_name) == 0
    end)
    staged.cleanup_state = {
        complete=#failures == 0,
        script_removed=script_removed,
        config_restored=config_restored,
        registrations_removed=registrations_removed,
        failures=failures,
    }
    if #failures > 0 then
        error('overlay registration cleanup failed: ' ..
            table.concat(failures, '; '), 0)
    end
end

---Stages one real overlay registration and owns exact external restoration.
---@param source_path string
---@param logical_name string
---@param run_id string
---@param project table
---@param cleanup table
---@param services table
---@return table
local function stage(source_path, logical_name, run_id, project, cleanup,
        services)
    assert(type(logical_name) == 'string' and
        logical_name:match('^[a-z][a-z0-9_-]*$'),
        'overlay registration name must contain lowercase letters, digits, ' ..
            'hyphens, or underscores')
    assert(type(run_id) == 'string' and run_id:match('^[%w_.-]+$'),
        'overlay staging requires a safe run id')
    assert(type(services.destination_directory) == 'string' and
        services.destination_directory ~= '',
        'overlay staging requires a destination directory')
    assert(type(services.config_path) == 'string' and
        services.config_path ~= '',
        'overlay staging requires an overlay configuration path')
    local source = project.resolve_lua_source(
        source_path, 'overlay registration')
    local leaf = ('dwarfspec_%s_%s.lua'):format(run_id, logical_name)
    local separator = package.config:sub(1, 1)
    local destination = services.destination_directory .. separator .. leaf
    assert(not services.isfile(destination),
        'refusing to overwrite an existing overlay registration script: ' ..
            destination)
    local source_contents = services.read_file(source.absolute_path)
    local config_existed = services.isfile(services.config_path)
    local config_contents = config_existed and
        services.read_file(services.config_path) or nil
    local staged = {
        name=logical_name,
        script_name=leaf:gsub('%.lua$', ''),
        path=destination,
        source=source.relative_path,
        registered_names={},
        cleanup_state={complete=false},
    }
    local marker = cleanup.mark()
    cleanup.register(
        'restore overlay registration ' .. logical_name, function()
            restore(staged, services, source_contents, config_existed,
                config_contents)
        end)
    local ok, failure = xpcall(function()
        services.write_file(destination, source_contents)
        services.rescan()
        staged.registered_names = services.registered_names(
            staged.script_name)
        assert(#staged.registered_names > 0,
            'staged script did not register any OVERLAY_WIDGETS')
    end, debug.traceback)
    if not ok then
        local cleanup_ok, cleanup_failures = cleanup.rollback(
            marker, 'failed overlay registration staging')
        local message = 'overlay registration staging failed: ' ..
            tostring(failure)
        if not cleanup_ok then
            local details = {}
            for _, cleanup_failure in ipairs(cleanup_failures) do
                table.insert(details, cleanup_failure.message)
            end
            message = message .. '; cleanup failed: ' ..
                table.concat(details, '; ')
        end
        error(message, 2)
    end
    return staged
end

---Constructs one run-scoped overlay registration workflow.
---@param capabilities table
---@return table
function M.new(capabilities)
    assert(type(capabilities) == 'table',
        'overlay registration requires run capabilities')
    local run_id = assert(capabilities.run_id,
        'overlay registration requires a run id')
    local project = assert(capabilities.project,
        'overlay registration requires project capabilities')
    local cleanup = assert(capabilities.cleanup,
        'overlay registration requires cleanup capabilities')
    local services = assert(capabilities.overlay,
        'overlay registration requires overlay capabilities')
    assert(type(project.resolve_lua_source) == 'function',
        'overlay registration requires project.resolve_lua_source()')
    for _, name in ipairs({'mark', 'register', 'rollback'}) do
        assert(type(cleanup[name]) == 'function',
            'overlay registration requires cleanup.' .. name .. '()')
    end
    for _, name in ipairs({
            'isfile', 'read_file', 'write_file', 'remove_file', 'rescan',
            'registered_names', 'is_enabled', 'disable'}) do
        assert(type(services[name]) == 'function',
            'overlay registration requires overlay.' .. name .. '()')
    end

    local workflow = {}

    ---Stages one run-owned overlay registration source.
    ---@param source_path string
    ---@param logical_name string
    ---@return table
    function workflow.stage(source_path, logical_name)
        return stage(source_path, logical_name, run_id, project, cleanup,
            services)
    end

    return workflow
end

return M
