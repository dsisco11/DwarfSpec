-- Cohesive run-scoped rendered-text search access.

local TextSearch = require('dwarfspec.driver.commands.text_search')

---@class dwarfspec.SearchRuntime
---@field private _mount_context table
---@field private _search function
local SearchRuntime = {}
SearchRuntime.__index = SearchRuntime

---Creates rendered-text search support for one run's active mount.
---@param options table
---@return dwarfspec.SearchRuntime
function SearchRuntime.new(options)
    assert(type(options) == 'table', 'search runtime options are required')
    assert(type(options.mount_context) == 'table',
        'search runtime requires a mount context')
    assert(type(options.matcher) == 'function',
        'search runtime requires rendered matching')
    local text_search = options.text_search or TextSearch
    assert(type(text_search) == 'table' and
            type(text_search.new_command) == 'function',
        'search runtime requires text-search primitives')
    return setmetatable({_mount_context=options.mount_context,
        _search=text_search.new_command({mount_context=options.mount_context,
            matcher=options.matcher})}, SearchRuntime)
end

---Returns whether one public value is a subject from this run.
---@param value any
---@return boolean
function SearchRuntime:is_subject(value)
    return self._mount_context:is_subject(value) or
        (type(value) == 'table' and
            type(value.control_path) == 'string' and
            (type(value._descriptor) == 'table' or
                (type(value.mount_id) == 'number' and
                    type(value._references) == 'table')))
end

---Revalidates the active mount and optional subject.
---@param subject table|nil
---@return table
function SearchRuntime:preflight(subject)
    local mount = self._mount_context:require_current('search')
    mount.interaction_target:assert_current('search')
    if subject ~= nil then
        self._mount_context:resolve_subject(subject, 'search')
    end
    return {target_identity=subject and subject.control_path or
        '<current-mount>'}
end

---Searches rendered text within an optional subject or rectangle.
---@param query table
---@param area any
---@param subject_scoped? boolean
---@return table|nil
function SearchRuntime:search(query, area, subject_scoped)
    return self._search(query, area, subject_scoped)
end

return SearchRuntime
