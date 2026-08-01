-- Narrow host capabilities supplied to one run-scoped DwarfSpec driver.

local M = {}

---Returns one required function from an injected dependency table.
---@param owner table
---@param name string
---@param label string
---@return function
local function require_function(owner, name, label)
    local value = owner and owner[name]
    assert(type(value) == 'function',
        ('run capabilities require %s.%s()'):format(label, name))
    return value
end

---Constructs the host capabilities available to one run-scoped driver.
---@param dependencies table
---@return table
function M.new(dependencies)
    assert(type(dependencies) == 'table',
        'run capabilities require dependencies')
    local run_id = dependencies.run_id
    assert(type(run_id) == 'string' and run_id:match('^[%w_.-]+$'),
        'run capabilities require a safe run id')

    local scheduler_module = assert(dependencies.scheduler_module,
        'run capabilities require a scheduler module')
    local scheduler = assert(dependencies.scheduler,
        'run capabilities require a scheduler')
    local wait_until_impl = require_function(
        scheduler_module, 'wait_until', 'scheduler')
    local wait_frames_impl = require_function(
        scheduler_module, 'wait_frames', 'scheduler')

    local cleanup_module = assert(dependencies.cleanup_module,
        'run capabilities require a cleanup module')
    local cleanup_registry = assert(dependencies.cleanup_registry,
        'run capabilities require a cleanup registry')
    local mark_impl = require_function(cleanup_module, 'mark', 'cleanup')
    local push_impl = require_function(cleanup_module, 'push', 'cleanup')
    local run_from_impl = require_function(
        cleanup_module, 'run_from', 'cleanup')

    local project_module = assert(dependencies.project_module,
        'run capabilities require a project-environment module')
    local relative_path_impl = require_function(
        project_module, 'relative_path', 'project environment')
    local join_impl = require_function(
        project_module, 'join', 'project environment')
    local project = assert(dependencies.project,
        'run capabilities require a project')
    assert(type(project.project_root) == 'string' and
            project.project_root ~= '' and
            type(project.filesystem) == 'table' and
            type(project.filesystem.isfile) == 'function',
        'run capabilities require a valid project environment')

    local overlay_services = assert(dependencies.overlay_services,
        'run capabilities require overlay services')
    assert(type(overlay_services.destination_directory) == 'string' and
            overlay_services.destination_directory ~= '',
        'run capabilities require an overlay destination directory')
    assert(type(overlay_services.config_path) == 'string' and
            overlay_services.config_path ~= '',
        'run capabilities require an overlay configuration path')
    local isfile_impl = require_function(
        overlay_services, 'isfile', 'overlay service')
    local read_file_impl = require_function(
        overlay_services, 'read_file', 'overlay service')
    local write_file_impl = require_function(
        overlay_services, 'write_file', 'overlay service')
    local remove_file_impl = require_function(
        overlay_services, 'remove_file', 'overlay service')
    local rescan_impl = require_function(
        overlay_services, 'rescan', 'overlay service')
    local registered_names_impl = require_function(
        overlay_services, 'registered_names', 'overlay service')
    local is_enabled_impl = require_function(
        overlay_services, 'is_enabled', 'overlay service')
    local disable_impl = require_function(
        overlay_services, 'disable', 'overlay service')

    ---Waits until one bounded run-owned condition succeeds.
    ---@param description string
    ---@param query function
    ---@param options table|nil
    ---@return any
    local function wait_until(description, query, options)
        return wait_until_impl(scheduler, description, query, options)
    end

    ---Waits for a bounded number of raw frames on the run scheduler.
    ---@param count integer
    ---@return any
    local function wait_frames(count)
        return wait_frames_impl(scheduler, count)
    end

    ---Marks the current run-owned cleanup position.
    ---@return integer
    local function mark_cleanup()
        return mark_impl(cleanup_registry)
    end

    ---Registers one labeled run-owned cleanup action.
    ---@param name string
    ---@param action function
    ---@return any
    local function register_cleanup(name, action)
        return push_impl(cleanup_registry, name, action)
    end

    ---Rolls back cleanup actions registered after one marker.
    ---@param marker integer
    ---@param reason string
    ---@return boolean, table
    local function rollback_cleanup(marker, reason)
        return run_from_impl(cleanup_registry, marker, reason)
    end

    ---Resolves one validated project-relative Lua source.
    ---@param source_path string
    ---@param purpose string|nil Optional diagnostic ownership label.
    ---@return table
    local function resolve_lua_source(source_path, purpose)
        assert(purpose == nil or
                type(purpose) == 'string' and purpose ~= '',
            'project source purpose must be a nonempty string')
        local source_label = purpose and purpose .. ' source' or
            'project Lua source'
        local relative_path = relative_path_impl(source_path)
        assert(relative_path:match('%.lua$'),
            source_label .. ' must name one Lua module: ' .. relative_path)
        local absolute_path = join_impl(project.project_root, relative_path)
        assert(project.filesystem.isfile(absolute_path),
            source_label .. ' was not found: ' .. relative_path)
        return {
            relative_path=relative_path,
            absolute_path=absolute_path,
        }
    end

    ---Returns whether one overlay-service path is a file.
    ---@param path string
    ---@return boolean
    local function overlay_isfile(path)
        return isfile_impl(path)
    end

    ---Reads one complete overlay-service file.
    ---@param path string
    ---@return string
    local function overlay_read_file(path)
        return read_file_impl(path)
    end

    ---Writes one complete overlay-service file.
    ---@param path string
    ---@param contents string
    ---@return any
    local function overlay_write_file(path, contents)
        return write_file_impl(path, contents)
    end

    ---Removes one overlay-service file.
    ---@param path string
    ---@return any
    local function overlay_remove_file(path)
        return remove_file_impl(path)
    end

    ---Rescans registered DFHack overlays.
    ---@return any
    local function overlay_rescan()
        return rescan_impl()
    end

    ---Returns registered overlay names owned by one script.
    ---@param script_name string
    ---@return string[]
    local function overlay_registered_names(script_name)
        return registered_names_impl(script_name)
    end

    ---Returns whether one registered overlay is enabled.
    ---@param name string
    ---@return boolean
    local function overlay_is_enabled(name)
        return is_enabled_impl(name)
    end

    ---Disables one registered overlay.
    ---@param name string
    ---@return any
    local function overlay_disable(name)
        return disable_impl(name)
    end

    return {
        run_id=run_id,
        scheduling={
            wait_until=wait_until,
            wait_frames=wait_frames,
        },
        cleanup={
            mark=mark_cleanup,
            register=register_cleanup,
            rollback=rollback_cleanup,
        },
        project={
            resolve_lua_source=resolve_lua_source,
        },
        overlay={
            destination_directory=overlay_services.destination_directory,
            config_path=overlay_services.config_path,
            isfile=overlay_isfile,
            read_file=overlay_read_file,
            write_file=overlay_write_file,
            remove_file=overlay_remove_file,
            rescan=overlay_rescan,
            registered_names=overlay_registered_names,
            is_enabled=overlay_is_enabled,
            disable=overlay_disable,
        },
    }
end

return M
