-- Safe run-scoped staging for explicitly imported overlay fixture definitions.

local M = {}

---Returns the directory portion of one normalized project-relative path.
---@param path string
---@return string
local function directory_name(path)
    return path:match('^(.*)/[^/]+$') or ''
end

---Loads and validates one explicitly imported overlay fixture definition.
---@param project table
---@param import_path string
---@param loader function|nil
---@return table
function M.load(project, import_path, loader)
local ok, project_module = pcall(require, 'dwarfspec.automation.project')
if not ok then
    project_module = assert(loadfile(project.package_root ..
        '/tests/automation/support/project.lua'))()
end
    local relative_path = project_module.relative_path(import_path)
    assert(relative_path:match('%.lua$'),
        'overlay fixture import must name one Lua module: ' .. relative_path)
    local absolute_path = project_module.join(project.project_root,
        relative_path)
    assert(project.filesystem.isfile(absolute_path),
        'overlay fixture definition was not found: ' .. relative_path)
    local chunk, load_error = (loader or loadfile)(absolute_path)
    assert(chunk, relative_path .. ': could not load overlay fixture: ' ..
        tostring(load_error))
    local ok, definition = xpcall(chunk, debug.traceback)
    assert(ok, relative_path .. ': overlay fixture failed to load: ' ..
        tostring(definition))
    assert(type(definition) == 'table',
        relative_path .. ': overlay fixture must return a table')
    assert(type(definition.name) == 'string' and
        definition.name:match('^[a-z][a-z0-9_-]*$'),
        relative_path .. ': overlay fixture name must contain lowercase ' ..
        'letters, digits, hyphens, or underscores')
    assert(type(definition.source) == 'string' and definition.source ~= '',
        relative_path .. ': overlay fixture source must be a nonempty string')
    local source_relative = project_module.relative_path(definition.source)
    local source_path = project_module.join(project.project_root,
        source_relative)
    assert(project.filesystem.isfile(source_path),
        relative_path .. ': overlay fixture source was not found: ' ..
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

---Writes one complete binary file without replacing an existing target.
---@param path string
---@param contents string
local function write_file(path, contents)
    local file, open_error = io.open(path, 'wb')
    assert(file, open_error)
    local ok, write_error = file:write(contents)
    file:close()
    assert(ok, write_error)
end

---Creates default DFHack services for overlay staging and rescanning.
---@return table
local function default_services()
    return {
        destination_directory=dfhack.getDFPath() .. '/hack/scripts/gui',
        isfile=dfhack.filesystem.isfile,
        read_file=read_file,
        write_file=write_file,
        remove_file=os.remove,
        rescan=function() require('plugins.overlay').rescan() end,
    }
end

---Stages one overlay fixture and registers exact removal plus a final rescan.
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
    local definition = M.load(project, import_path, services.loadfile)
    local leaf = ('dwarfspec_%s_%s.lua'):format(run_id, definition.name)
    local separator = package.config:sub(1, 1)
    local destination = services.destination_directory .. separator .. leaf
    assert(not services.isfile(destination),
        'refusing to overwrite an existing overlay fixture: ' .. destination)
    local contents = services.read_file(definition.source_path)
    services.write_file(destination, contents)
    local rescan_ok, rescan_error = pcall(services.rescan)
    if not rescan_ok then
        pcall(services.remove_file, destination)
        pcall(services.rescan)
        error('overlay fixture rescan failed: ' .. tostring(rescan_error), 2)
    end
    cleanup_module.push(cleanup_registry,
        'remove overlay fixture ' .. definition.name, function()
            assert(destination == services.destination_directory ..
                separator .. leaf and
                leaf:match('^dwarfspec_[%w_.-]+_[a-z][a-z0-9_-]*%.lua$'),
                'refusing to remove an unexpected overlay fixture path')
            if services.isfile(destination) then
                local removed, remove_error =
                    services.remove_file(destination)
                assert(removed ~= false and removed ~= nil, remove_error)
            end
            services.rescan()
        end)
    return {
        name=definition.name,
        script_name=leaf:gsub('%.lua$', ''),
        path=destination,
        source=definition.source,
    }
end

return M
