-- Version 2 latest-invocation result construction and safe persistence.

local json = require('dkjson')
local project = require('dwarfspec.project')
local projects = require('dwarfspec.automation.projects')
local schemas = require('dwarfspec.automation.schemas')

local M = {
    default_relative_path='tests/.test-results/dwarfspec/results.json',
}

---Returns the exact normalized result path or nil for no-results policy.
---@param project_root string
---@param configured_path string|false|nil
---@param filesystem table|nil
---@return string|nil
function M.resolve_path(project_root, configured_path, filesystem)
    if configured_path == false then return nil end
    configured_path = configured_path or M.default_relative_path
    if not project.is_absolute(project_root) then
        if project.is_absolute(configured_path) then
            return project.normalize(configured_path)
        end
        return project.normalize(project.join(project_root, configured_path))
    end
    return projects.normalize_file_path(configured_path, project_root,
        filesystem)
end

---Constructs and validates one version 2 invocation result.
---@param source table
---@return table
function M.build(source)
    assert(type(source) == 'table',
        'result construction source must be a table')
    local result = {
        schema='dwarfspec.result.v2',
        service_instance_id=source.service_instance_id,
        project_id=source.project_id,
        run_id=source.run_id,
        generation=source.generation,
        state=source.state,
        terminal=source.terminal,
        exit_code=source.exit_code,
        project_root=source.project_root,
        selection=source.selection or {identities={}},
        submitted_at=source.submitted_at,
        activated_at=source.activated_at,
        finished_at=source.finished_at,
        queue_wait_ms=source.queue_wait_ms,
        error=source.error,
        host_report=source.host_report,
        events=source.events or {},
    }
    schemas.validate_result(result)
    return result
end

---Reads one file completely if it exists.
---@param path string
---@return string|nil
local function read_existing(path)
    local file = io.open(path, 'rb')
    if not file then return nil end
    local contents = file:read('*a')
    file:close()
    return contents
end

---Restores previous contents after a platform replacement failure.
---@param path string
---@param contents string
local function restore_existing(path, contents)
    local file, open_error = io.open(path, 'wb')
    assert(file, 'could not restore previous result: ' ..
        tostring(open_error))
    local ok, write_error = file:write(contents)
    file:close()
    assert(ok, 'could not restore previous result: ' ..
        tostring(write_error))
end

---Replaces one destination with a fully written temporary sibling.
---@param temporary_path string
---@param result_path string
---@return boolean|nil, string|nil
local function replace_file(temporary_path, result_path)
    local replaced, replace_error = os.rename(temporary_path, result_path)
    if replaced then return true end
    local previous = read_existing(result_path)
    if previous == nil then return nil, replace_error end
    local removed, remove_error = os.remove(result_path)
    if not removed then return nil, remove_error end
    replaced, replace_error = os.rename(temporary_path, result_path)
    if replaced then return true end
    restore_existing(result_path, previous)
    return nil, replace_error
end

---Encodes one validated result with a trailing newline.
---@param result table
---@param encoder function|nil
---@return string
local function encode_result(result, encoder)
    if encoder then return encoder(result) end
    local contents = assert(json.encode(result, {indent=true}))
    return contents .. '\n'
end

---Writes a result through one temporary sibling and cleans it on every path.
---@param result_path string
---@param result table
---@param dependencies table|nil
function M.write(result_path, result, dependencies)
    assert(type(result_path) == 'string' and result_path ~= '',
        'result path must be a nonempty string')
    schemas.validate_result(result)
    dependencies = dependencies or {}
    local filesystem = dependencies.filesystem or project.filesystem()
    local open_file = dependencies.open_file or io.open
    local remove_file = dependencies.remove_file or os.remove
    local replace = dependencies.replace_file or replace_file
    local temporary_path = result_path .. '.tmp'
    local directory = assert(result_path:match('^(.*)/[^/]+$'),
        'result path must have a parent directory')
    project.mkdir_p(directory, filesystem)
    remove_file(temporary_path)

    local ok, write_error = xpcall(function()
        local file, open_error = open_file(temporary_path, 'wb')
        assert(file, 'could not open temporary result: ' ..
            tostring(open_error))
        local wrote, file_error = file:write(
            encode_result(result, dependencies.encode))
        local closed, close_error = file:close()
        assert(wrote, 'could not write temporary result: ' ..
            tostring(file_error))
        assert(closed, 'could not close temporary result: ' ..
            tostring(close_error))
        local replaced, replace_error = replace(temporary_path, result_path)
        assert(replaced, 'could not replace result file: ' ..
            tostring(replace_error))
    end, function(value) return value end)
    if not ok then
        remove_file(temporary_path)
        error(write_error, 0)
    end
end

return M
