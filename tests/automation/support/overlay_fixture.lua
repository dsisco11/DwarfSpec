-- Reversible run-scoped staging for real DFHack overlay registration tests.

local M = {}

---Returns the directory portion of one normalized project-relative path.
---@param path string
---@return string
local function directory_name(path)
    return path:match('^(.*)/[^/]+$') or ''
end

---Loads and validates one explicitly imported overlay registration definition.
---@param project table
---@param import_path string
---@param loader function|nil
---@return table
function M.load(project, import_path, loader)
    local ok, project_module = pcall(require,
        'dwarfspec.automation.project')
    if not ok then
        project_module = assert(loadfile(project.package_root ..
            '/tests/automation/support/project.lua'))()
    end
    local relative_path = project_module.relative_path(import_path)
    assert(relative_path:match('%.lua$'),
        'overlay registration import must name one Lua module: ' ..
            relative_path)
    local absolute_path = project_module.join(project.project_root,
        relative_path)
    assert(project.filesystem.isfile(absolute_path),
        'overlay registration definition was not found: ' .. relative_path)
    local chunk, load_error = (loader or loadfile)(absolute_path)
    assert(chunk, relative_path .. ': could not load overlay registration: ' ..
        tostring(load_error))
    local loaded, definition = xpcall(chunk, debug.traceback)
    assert(loaded, relative_path .. ': overlay registration failed to load: ' ..
        tostring(definition))
    assert(type(definition) == 'table',
        relative_path .. ': overlay registration must return a table')
    assert(type(definition.name) == 'string' and
        definition.name:match('^[a-z][a-z0-9_-]*$'),
        relative_path .. ': overlay registration name must contain lowercase ' ..
        'letters, digits, hyphens, or underscores')
    assert(type(definition.source) == 'string' and definition.source ~= '',
        relative_path .. ': overlay registration source must be a nonempty ' ..
        'string')
    local source_relative = project_module.relative_path(definition.source)
    local source_path = project_module.join(project.project_root,
        source_relative)
    assert(project.filesystem.isfile(source_path),
        relative_path .. ': overlay registration source was not found: ' ..
        source_relative)
    return {
        name=definition.name,
        source=source_relative,
        source_path=source_path,
        definition=relative_path,
        definition_directory=directory_name(relative_path),
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
---@param import_path string
---@param run_id string
---@param cleanup_module table
---@param cleanup_registry table
---@param services table|nil
---@return table
function M.stage(project, import_path, run_id, cleanup_module,
        cleanup_registry, services)
    assert(type(run_id) == 'string' and run_id:match('^[%w_.-]+$'),
        'overlay staging requires a safe run id')
    services = services or default_services()
    assert(type(services.destination_directory) == 'string' and
        services.destination_directory ~= '',
        'overlay staging requires a destination directory')
    assert(type(services.config_path) == 'string' and
        services.config_path ~= '',
        'overlay staging requires an overlay configuration path')
    local definition = M.load(project, import_path, services.loadfile)
    local leaf = ('dwarfspec_%s_%s.lua'):format(run_id, definition.name)
    local separator = package.config:sub(1, 1)
    local destination = services.destination_directory .. separator .. leaf
    assert(not services.isfile(destination),
        'refusing to overwrite an existing overlay registration script: ' ..
            destination)
    local source_contents = services.read_file(definition.source_path)
    local config_existed = services.isfile(services.config_path)
    local config_contents = config_existed and
        services.read_file(services.config_path) or nil
    local staged = {
        name=definition.name,
        script_name=leaf:gsub('%.lua$', ''),
        path=destination,
        source=definition.source,
        registered_names={},
        cleanup_state={complete=false},
    }
    local marker = cleanup_module.mark(cleanup_registry)
    cleanup_module.push(cleanup_registry,
        'restore overlay registration ' .. definition.name, function()
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
