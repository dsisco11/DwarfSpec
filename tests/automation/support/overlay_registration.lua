-- Reversible run-scoped staging for real DFHack overlay registration tests.

local M = {}

---Resolves one directly imported overlay registration source module.
---@param project table
---@param source_path string
---@return table
local function resolve_source(project, source_path)
    local ok, project_module = pcall(require,
        'dwarfspec.automation.project')
    if not ok then
        project_module = assert(loadfile(project.package_root ..
            '/tests/automation/support/project.lua'))()
    end
    local relative_path = project_module.relative_path(source_path)
    assert(relative_path:match('%.lua$'),
        'overlay registration source must name one Lua module: ' ..
            relative_path)
    local absolute_path = project_module.join(project.project_root,
        relative_path)
    assert(project.filesystem.isfile(absolute_path),
        'overlay registration source was not found: ' .. relative_path)
    return {
        relative_path=relative_path,
        absolute_path=absolute_path,
    }
end

---Reads one complete binary file or raises its operating-system error.
---@param path string
---@return string
local function read_file(path)
    local file, open_error = io.open(path, 'rb')
    assert(file, open_error)
    local contents = file:read('*a')
    file:close()
    return contents
end

---Writes one complete binary file or raises its operating-system error.
---@param path string
---@param contents string
local function write_file(path, contents)
    local file, open_error = io.open(path, 'wb')
    assert(file, open_error)
    local written, write_error = file:write(contents)
    file:close()
    assert(written, write_error)
end

---Creates default DFHack services for registration and configuration cleanup.
---@return table
local function default_services()
    local overlay = require('plugins.overlay')
    return {
        destination_directory=dfhack.getDFPath() .. '/hack/scripts/gui',
        config_path=dfhack.getDFPath() .. '/dfhack-config/overlay.json',
        isfile=dfhack.filesystem.isfile,
        read_file=read_file,
        write_file=write_file,
        remove_file=os.remove,
        rescan=function() overlay.rescan() end,
        registered_names=function(script_name)
            local prefix = 'gui/' .. script_name .. '.'
            local names = {}
            for name in pairs(overlay.get_state().db) do
                if name:sub(1, #prefix) == prefix then
                    table.insert(names, name)
                end
            end
            table.sort(names)
            return names
        end,
        is_enabled=function(name)
            return not not overlay.isOverlayEnabled(name)
        end,
        disable=function(name)
            overlay.overlay_command({'disable', name}, true)
            assert(not overlay.isOverlayEnabled(name),
                'overlay remained enabled after disable: ' .. name)
        end,
    }
end

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
---@param project table
---@param source_path string
---@param logical_name string
---@param run_id string
---@param cleanup_module table
---@param cleanup_registry table
---@param services table|nil
---@return table
function M.stage(project, source_path, logical_name, run_id, cleanup_module,
        cleanup_registry, services)
    assert(type(logical_name) == 'string' and
        logical_name:match('^[a-z][a-z0-9_-]*$'),
        'overlay registration name must contain lowercase letters, digits, ' ..
            'hyphens, or underscores')
    assert(type(run_id) == 'string' and run_id:match('^[%w_.-]+$'),
        'overlay staging requires a safe run id')
    services = services or default_services()
    assert(type(services.destination_directory) == 'string' and
        services.destination_directory ~= '',
        'overlay staging requires a destination directory')
    assert(type(services.config_path) == 'string' and
        services.config_path ~= '',
        'overlay staging requires an overlay configuration path')
    local source = resolve_source(project, source_path)
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
    local marker = cleanup_module.mark(cleanup_registry)
    cleanup_module.push(cleanup_registry,
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
        local cleanup_ok, cleanup_failures = cleanup_module.run_from(
            cleanup_registry, marker, 'failed overlay registration staging')
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

return M
