-- Validated request records for native and overlay subject selection.

local ESubjectSource = require('dwarfspec.subject_sources')
local subject_paths = require('dwarfspec.subject_paths')

local M = {}

local source_members = {}
for _, value in pairs(ESubjectSource) do source_members[value] = true end

---@class dwarfspec.SubjectSourceOptions
---@field source? DwarfSpecESubjectSource
---@field overlay? string
---@field native_root? any

---@class dwarfspec.SubjectSourceRequest
---@field source DwarfSpecESubjectSource
---@field overlay string|nil
---@field native_root any|nil

---@class dwarfspec.SubjectGetRequest: dwarfspec.SubjectSourceRequest
---@field path_segments dwarfspec.NativePath

---Validates one optional source-selection table and applies native defaults.
---@param options any
---@return dwarfspec.SubjectSourceRequest
local function normalize_options(options)
    assert(options == nil or type(options) == 'table',
        'subject source options must be a table')
    options = options or {}
    for name in pairs(options) do
        assert(name == 'source' or name == 'overlay' or
            name == 'native_root',
            'unsupported subject source option: ' .. tostring(name))
    end

    local source = options.source
    if source == nil then source = ESubjectSource.NATIVE end
    assert(type(source) == 'string' and source_members[source],
        'unsupported subject source: ' .. tostring(source))
    if source == ESubjectSource.OVERLAY then
        assert(type(options.overlay) == 'string' and options.overlay ~= '',
            'overlay subject source requires an exact nonempty overlay name')
        assert(options.native_root == nil,
            'native_root option conflicts with overlay subject source')
    else
        assert(options.overlay == nil,
            'overlay option conflicts with native subject source')
    end
    return {
        source=source,
        overlay=options.overlay,
        native_root=options.native_root,
    }
end

---Creates one validated root-selection request.
---@param options dwarfspec.SubjectSourceOptions|nil
---@return dwarfspec.SubjectSourceRequest
function M.root(options)
    return normalize_options(options)
end

---Creates one validated source-specific path selection request.
---@param control_path string|dwarfspec.NativePath
---@param options dwarfspec.SubjectSourceOptions|nil
---@return dwarfspec.SubjectGetRequest
function M.get(control_path, options)
    local request = normalize_options(options)
    if request.source == ESubjectSource.NATIVE then
        request.path_segments = subject_paths.native(control_path)
    else
        request.path_segments = subject_paths.component(control_path)
    end
    return request
end

---Creates one validated tree-capture source request.
---@param options dwarfspec.SubjectSourceOptions|nil
---@return dwarfspec.SubjectSourceRequest
function M.tree(options)
    return normalize_options(options)
end

return M
