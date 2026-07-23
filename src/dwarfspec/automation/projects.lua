-- Internal copy-on-write project registry operations for the automation service.

local ResultPolicy = require('dwarfspec.automation.result_policies')

local M = {}

local RESULT_POLICIES = {
    [ResultPolicy.FILE]=true,
    [ResultPolicy.NONE]=true,
}

---Returns whether the active Lua platform uses case-insensitive Windows paths.
---@param filesystem table|nil
---@return boolean
local function case_insensitive_paths(filesystem)
    if filesystem and filesystem.case_insensitive ~= nil then
        return filesystem.case_insensitive == true
    end
    return package.config:sub(1, 1) == '\\'
end

---Returns whether a normalized path is absolute.
---@param path string
---@return boolean
local function is_absolute(path)
    return path:match('^/') ~= nil or
        path:match('^[A-Za-z]:/') ~= nil
end

---Normalizes separators and lexical current- and parent-directory segments.
---@param path string
---@return string
local function normalize_absolute_path(path)
    local normalized = path:gsub('\\', '/'):gsub('/+', '/')
    local prefix
    local remainder
    local drive = normalized:match('^([A-Za-z]:)/')
    if drive then
        prefix = drive:upper() .. '/'
        remainder = normalized:sub(4)
    elseif normalized:sub(1, 1) == '/' then
        prefix = '/'
        remainder = normalized:sub(2)
    else
        prefix = ''
        remainder = normalized
    end

    local segments = {}
    for segment in remainder:gmatch('[^/]+') do
        if segment == '..' then
            assert(#segments > 0,
                'path must not escape its absolute root: ' .. path)
            table.remove(segments)
        elseif segment ~= '.' and segment ~= '' then
            table.insert(segments, segment)
        end
    end
    local collapsed = prefix .. table.concat(segments, '/')
    if collapsed == '' and prefix ~= '' then return prefix end
    return collapsed
end

---Creates the default filesystem surface used for project-root normalization.
---@return table
local function default_filesystem()
    local lfs = require('lfs')

    ---Returns whether one path names an existing directory.
    ---@param path string
    ---@return boolean
    local function is_directory(path)
        return lfs.attributes(path, 'mode') == 'directory'
    end

    return {
        currentdir=lfs.currentdir,
        isdir=is_directory,
    }
end

---Returns the JSON container kind and maximum array index.
---@param value table
---@param path string
---@return string, integer
local function container_kind(value, path)
    local string_keys = 0
    local numeric_keys = 0
    local maximum = 0
    for key in pairs(value) do
        if type(key) == 'string' then
            string_keys = string_keys + 1
        elseif type(key) == 'number' and key >= 1 and key % 1 == 0 then
            numeric_keys = numeric_keys + 1
            maximum = math.max(maximum, key)
        else
            error(('JSON-safe table %s has unsupported key %s')
                :format(path, tostring(key)), 0)
        end
    end
    assert(string_keys == 0 or numeric_keys == 0,
        'JSON-safe table ' .. path .. ' mixes object and array keys')
    if numeric_keys > 0 then
        assert(maximum == numeric_keys,
            'JSON-safe array ' .. path .. ' must be dense')
        return 'array', maximum
    end
    return 'object', string_keys
end

---Copies one JSON-safe value while rejecting cycles and live runtime objects.
---@param value any
---@param path string
---@param active table
---@return any
local function copy_json_value(value, path, active)
    local value_type = type(value)
    if value_type == 'nil' or value_type == 'boolean' or
            value_type == 'string' then
        return value
    end
    if value_type == 'number' then
        assert(value == value and value ~= math.huge and value ~= -math.huge,
            'JSON-safe number ' .. path .. ' must be finite')
        return value
    end
    assert(value_type == 'table',
        ('JSON-safe value %s has unsupported type %s'):format(
            path, value_type))
    assert(getmetatable(value) == nil,
        'JSON-safe table ' .. path .. ' must not have a metatable')
    assert(active[value] == nil, 'JSON-safe value contains a cycle at ' .. path)

    active[value] = true
    local result = {}
    local kind, maximum = container_kind(value, path)
    if kind == 'array' then
        for index = 1, maximum do
            result[index] = copy_json_value(value[index],
                ('%s[%d]'):format(path, index), active)
        end
    else
        for key, child in pairs(value) do
            result[key] = copy_json_value(child, path .. '.' .. key, active)
        end
    end
    active[value] = nil
    return result
end

---Copies one ordinary JSON-safe value into detached service-owned data.
---@param value any
---@param path string|nil
---@return any
function M.copy_json(value, path)
    return copy_json_value(value, path or 'value', {})
end

---Returns one lexically normalized absolute project root and comparison key.
---This does not resolve filesystem aliases such as symlinks or junctions.
---@param root string
---@param filesystem table|nil
---@return string, string
function M.normalize_root(root, filesystem)
    assert(type(root) == 'string' and root ~= '',
        'project root must be a nonempty string')
    filesystem = filesystem or default_filesystem()
    assert(type(filesystem.currentdir) == 'function' and
        type(filesystem.isdir) == 'function',
        'project filesystem must provide currentdir and isdir')

    local candidate = root
    if not is_absolute(candidate:gsub('\\', '/')) then
        candidate = filesystem.currentdir() .. '/' .. candidate
    end
    candidate = normalize_absolute_path(candidate)
    assert(is_absolute(candidate),
        'normalized project root must be absolute: ' .. candidate)
    assert(filesystem.isdir(candidate),
        'project root is not a directory: ' .. candidate)

    local identity = candidate
    if case_insensitive_paths(filesystem) then identity = identity:lower() end
    return candidate, identity
end

---Returns a lexically normalized absolute file path and comparison identity.
---The path need not exist; filesystem aliases are not resolved.
---@param path string
---@param base_root string
---@param filesystem table|nil
---@return string, string
function M.normalize_file_path(path, base_root, filesystem)
    assert(type(path) == 'string' and path ~= '',
        'file path must be a nonempty string')
    assert(type(base_root) == 'string' and base_root ~= '',
        'file path base root must be a nonempty string')
    local candidate = path
    local relative = not is_absolute(candidate:gsub('\\', '/'))
    if relative then
        candidate = base_root .. '/' .. candidate
    end
    candidate = normalize_absolute_path(candidate)
    assert(is_absolute(candidate),
        'normalized file path must be absolute: ' .. candidate)
    local normalized_base = normalize_absolute_path(base_root)
    local containment_path = candidate
    local containment_base = normalized_base
    if case_insensitive_paths(filesystem) then
        containment_path = containment_path:lower()
        containment_base = containment_base:lower()
    end
    if relative then
        assert(containment_path:sub(1, #containment_base + 1) ==
            containment_base .. '/',
            'relative file path must remain beneath its project root')
    end
    local identity = candidate
    if case_insensitive_paths(filesystem) then identity = identity:lower() end
    return candidate, identity
end

---Returns a default display name derived from one normalized root.
---@param normalized_root string
---@return string
local function default_display_name(normalized_root)
    return normalized_root:match('([^/]+)$') or normalized_root
end

---Returns one detached public project summary.
---@param project table
---@return table
local function summary(project)
    return M.copy_json({
        project_id=project.project_id,
        normalized_project_root=project.normalized_project_root,
        display_name=project.display_name,
        normalized_configuration=project.normalized_configuration,
        result_path=project.result_path,
        result_policy=project.result_policy,
        client_compatibility=project.client_compatibility,
        registered_at=project.registered_at,
        refreshed_at=project.refreshed_at,
        outstanding_run_id=project.outstanding_run_id,
    }, 'project summary')
end

---Returns the record with one normalized path identity, if registered.
---@param projects table
---@param identity string
---@return table|nil
local function find_by_identity(projects, identity)
    for _, project in pairs(projects) do
        if project.normalized_identity == identity then return project end
    end
    return nil
end

---Validates and normalizes one registration request.
---@param request table
---@param filesystem table|nil
---@return table
local function normalize_request(request, filesystem)
    assert(type(request) == 'table',
        'project registration request must be a table')
    local normalized_root, identity = M.normalize_root(
        request.project_root, filesystem)
    local display_name = request.display_name or
        default_display_name(normalized_root)
    assert(type(display_name) == 'string' and display_name ~= '',
        'project display name must be a nonempty string')

    local result_policy = request.result_policy == nil and ResultPolicy.FILE or
        request.result_policy
    assert(RESULT_POLICIES[result_policy] == true,
        'project result policy must be file or none')
    local result_path = request.result_path
    if result_policy == ResultPolicy.FILE then
        assert(type(result_path) == 'string' and result_path ~= '',
            'file-backed project registration requires a result path')
    else
        assert(result_path == nil,
            'no-results project registration must not provide a result path')
    end

    assert(type(request.client_compatibility) == 'table',
        'project client compatibility must be a table')
    return {
        requested_project_id=request.project_id,
        normalized_project_root=normalized_root,
        normalized_identity=identity,
        display_name=display_name,
        normalized_configuration=M.copy_json(
            request.normalized_configuration or {},
            'normalized project configuration'),
        result_path=result_path,
        result_policy=result_policy,
        client_compatibility=M.copy_json(request.client_compatibility,
            'project client compatibility'),
    }
end

---Registers or refreshes a project through a copy-on-write project map.
---@param projects table
---@param request table
---@param context table
---@return table, table
function M.register(projects, request, context)
    assert(type(projects) == 'table', 'projects must be a table')
    assert(type(context) == 'table' and type(context.now_ms) == 'function' and
        type(context.next_project_id) == 'function',
        'project registration context is incomplete')
    local normalized = normalize_request(request, context.filesystem)
    local requested_id = normalized.requested_project_id
    local requested_record = requested_id and projects[requested_id] or nil
    if requested_id and not requested_record then
        error('registered project id was not found: ' .. requested_id, 0)
    end
    if requested_record and
            requested_record.normalized_identity ~=
                normalized.normalized_identity then
        error(('project id %s belongs to a different normalized root')
            :format(requested_id), 0)
    end

    local existing = find_by_identity(projects,
        normalized.normalized_identity)
    if existing and requested_id and existing.project_id ~= requested_id then
        error(('normalized project root is already registered as %s')
            :format(existing.project_id), 0)
    end

    local now_ms = context.now_ms()
    assert(type(now_ms) == 'number' and now_ms >= 0,
        'project registration time must be nonnegative')
    local project_id = existing and existing.project_id or
        context.next_project_id()
    assert(type(project_id) == 'string' and project_id ~= '',
        'project id generator returned an invalid identifier')
    assert(existing or projects[project_id] == nil,
        'project id generator returned an existing identifier')

    local project = {
        project_id=project_id,
        normalized_project_root=existing and
            existing.normalized_project_root or
            normalized.normalized_project_root,
        normalized_identity=normalized.normalized_identity,
        display_name=normalized.display_name,
        normalized_configuration=normalized.normalized_configuration,
        result_path=normalized.result_path,
        result_policy=normalized.result_policy,
        client_compatibility=normalized.client_compatibility,
        request_keys=existing and existing.request_keys or {},
        registered_at=existing and existing.registered_at or now_ms,
        refreshed_at=now_ms,
        outstanding_run_id=existing and existing.outstanding_run_id or nil,
    }
    local updated = {}
    for id, record in pairs(projects) do updated[id] = record end
    updated[project_id] = project
    return updated, summary(project)
end

---Returns one detached project summary by identifier.
---@param projects table
---@param project_id string
---@return table|nil
function M.lookup(projects, project_id)
    assert(type(projects) == 'table', 'projects must be a table')
    assert(type(project_id) == 'string' and project_id ~= '',
        'project id must be a nonempty string')
    local project = projects[project_id]
    return project and summary(project) or nil
end

---Returns detached project summaries in deterministic registration order.
---@param projects table
---@return table[]
function M.list(projects)
    assert(type(projects) == 'table', 'projects must be a table')
    local result = {}
    for _, project in pairs(projects) do
        table.insert(result, summary(project))
    end

    ---Orders project summaries by registration and stable identity.
    ---@param left table
    ---@param right table
    ---@return boolean
    local function registered_before(left, right)
        if left.registered_at ~= right.registered_at then
            return left.registered_at < right.registered_at
        end
        return left.project_id < right.project_id
    end

    table.sort(result, registered_before)
    return result
end

---Unregisters one idle project through a copy-on-write project map.
---@param projects table
---@param project_id string
---@return table, table
function M.unregister(projects, project_id)
    assert(type(projects) == 'table', 'projects must be a table')
    assert(type(project_id) == 'string' and project_id ~= '',
        'project id must be a nonempty string')
    local project = projects[project_id]
    if not project then
        error('registered project id was not found: ' .. project_id, 0)
    end
    if project.outstanding_run_id ~= nil then
        error(('project %s still owns outstanding run %s')
            :format(project_id, tostring(project.outstanding_run_id)), 0)
    end

    local updated = {}
    for id, record in pairs(projects) do
        if id ~= project_id then updated[id] = record end
    end
    return updated, summary(project)
end

return M
