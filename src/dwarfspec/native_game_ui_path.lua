-- Deterministic structural-to-widget path resolution for native game UI.

local immutable_enum = require('dwarfspec.immutable_enum')

local M = {}

local FIELD_SUMMARY_LIMIT = 12
local LABEL_LIMIT = 80

---@enum DwarfSpecEGameUIFieldKind
M.EFieldKind = immutable_enum.define({
    COMPOUND='compound',
    WIDGET='widget',
    SCALAR='scalar',
    FUNCTION='function',
    COLLECTION='collection',
    POINTER='pointer',
})

---@enum DwarfSpecEGameUIPathFailureKind
M.EFailureKind = immutable_enum.define({
    INVALID_PATH='invalid_path',
    MAIN_INTERFACE_UNAVAILABLE='main_interface_unavailable',
    TYPE_UNAVAILABLE='type_unavailable',
    FIELD_METADATA_UNAVAILABLE='field_metadata_unavailable',
    INVALID_STRUCTURAL_SEGMENT='invalid_structural_segment',
    MISSING_FIELD='missing_field',
    UNSUPPORTED_FIELD='unsupported_field',
    FIELD_ACCESS_FAILED='field_access_failed',
    UNSUPPORTED_FIELD_VALUE='unsupported_field_value',
    WIDGET_LOOKUP_FAILED='widget_lookup_failed',
    MISSING_WIDGET='missing_widget',
    FINAL_NOT_WIDGET='final_not_widget',
    IDENTITY_UNAVAILABLE='identity_unavailable',
})

local field_kind_members = {}
for _, value in pairs(M.EFieldKind) do field_kind_members[value] = true end

---@class dwarfspec.GameUIPathFailure
---@field kind DwarfSpecEGameUIPathFailureKind
---@field index integer|nil
---@field segment string|integer|nil
---@field current_type string|nil
---@field field_kind DwarfSpecEGameUIFieldKind|nil
---@field detail string|nil
---@field available_fields string[]|nil
---@field omitted_field_count integer|nil

---@class dwarfspec.GameUIPathResolution
---@field path dwarfspec.NativePath
---@field structural_segments string[]
---@field widget_segments dwarfspec.NativePath
---@field widget_root any|nil
---@field widget_root_identity any|nil
---@field widget any|nil
---@field widget_identity any|nil
---@field failure dwarfspec.GameUIPathFailure|nil

---@class dwarfspec.NativeGameUIPathResolver
---@field _get_main_interface function
---@field _get_type function
---@field _get_fields function
---@field _read_field function
---@field _is_widget function
---@field _is_container function
---@field _get_widget function
---@field _identity_of function
local NativeGameUIPathResolver = {}
NativeGameUIPathResolver.__index = NativeGameUIPathResolver

---Copies an array without retaining caller-owned path storage.
---@param values table
---@return table
local function copy_array(values)
    local result = {}
    for index, value in ipairs(values) do result[index] = value end
    return result
end

---Returns a bounded scalar label for failure evidence.
---@param value any
---@return string
local function bounded_label(value)
    local label = tostring(value)
    if #label <= LABEL_LIMIT then return label end
    return label:sub(1, LABEL_LIMIT - 3) .. '...'
end

---Calls one injected predicate and accepts only an exact true result.
---@param predicate function
---@param value any
---@return boolean
local function safe_predicate(predicate, value)
    local ok, result = pcall(predicate, value)
    return ok and result == true
end

---Returns a bounded type label without propagating injected failures.
---@param self dwarfspec.NativeGameUIPathResolver
---@param value any
---@return string|nil
local function safe_type_label(self, value)
    local ok, type_descriptor = pcall(self._get_type, value)
    if not ok or type_descriptor == nil then return nil end
    return bounded_label(type_descriptor)
end

---Creates an empty resolution record for one copied path.
---@param path table
---@return dwarfspec.GameUIPathResolution
local function new_resolution(path)
    return {
        path=copy_array(path),
        structural_segments={},
        widget_segments={},
        widget_root=nil,
        widget_root_identity=nil,
        widget=nil,
        widget_identity=nil,
        failure=nil,
    }
end

---Attaches one expected failure to a resolution record.
---@param resolution dwarfspec.GameUIPathResolution
---@param kind DwarfSpecEGameUIPathFailureKind
---@param values table|nil
---@return dwarfspec.GameUIPathResolution
local function fail(resolution, kind, values)
    local failure = {kind=kind}
    for name, value in pairs(values or {}) do failure[name] = value end
    resolution.failure = failure
    return resolution
end

---Returns bounded deterministic declared-field names for diagnostics.
---@param fields table
---@return string[], integer
local function summarize_fields(fields)
    local names = {}
    for name, metadata in pairs(fields) do
        if type(name) == 'string' and type(metadata) == 'table' then
            table.insert(names, bounded_label(name))
        end
    end
    table.sort(names)
    local summary = {}
    for index = 1, math.min(#names, FIELD_SUMMARY_LIMIT) do
        summary[index] = names[index]
    end
    return summary, math.max(0, #names - #summary)
end

---Validates and copies a complete native path shape.
---@param path any
---@return table|nil, integer|nil, any|nil
local function normalize_path(path)
    if type(path) ~= 'table' or #path == 0 then return nil, nil, nil end
    local result = {}
    for index = 1, #path do
        local segment = path[index]
        if type(segment) == 'string' then
            if segment == '' then return nil, index, segment end
        elseif type(segment) == 'number' then
            if segment < 0 or segment % 1 ~= 0 then
                return nil, index, segment
            end
        else
            return nil, index, segment
        end
        result[index] = segment
    end
    for key in pairs(path) do
        if type(key) ~= 'number' or key % 1 ~= 0 or
                key < 1 or key > #path then
            return nil, nil, nil
        end
    end
    return result
end

---Reads the exact declared-field table for one structural object.
---@param self dwarfspec.NativeGameUIPathResolver
---@param current any
---@param resolution dwarfspec.GameUIPathResolution
---@param index integer
---@param segment string|integer
---@return any|nil, table|nil
local function declared_fields(self, current, resolution, index, segment)
    local type_ok, type_descriptor = pcall(self._get_type, current)
    if not type_ok or type_descriptor == nil then
        fail(resolution, M.EFailureKind.TYPE_UNAVAILABLE, {
            index=index,
            segment=segment,
            detail=bounded_label(type_descriptor),
        })
        return nil
    end
    local fields_ok, fields = pcall(self._get_fields, type_descriptor)
    if not fields_ok or type(fields) ~= 'table' then
        fail(resolution, M.EFailureKind.FIELD_METADATA_UNAVAILABLE, {
            index=index,
            segment=segment,
            current_type=bounded_label(type_descriptor),
            detail=bounded_label(fields),
        })
        return nil
    end
    return type_descriptor, fields
end

---Returns whether one declared field kind can continue structural traversal.
---@param kind DwarfSpecEGameUIFieldKind
---@return boolean
local function is_traversable_field(kind)
    return kind == M.EFieldKind.COMPOUND or
        kind == M.EFieldKind.WIDGET
end

---Resolves the widget suffix without returning to structural traversal.
---@param self dwarfspec.NativeGameUIPathResolver
---@param current any
---@param path table
---@param start_index integer
---@param resolution dwarfspec.GameUIPathResolution
---@return dwarfspec.GameUIPathResolution
local function resolve_widgets(
        self, current, path, start_index, resolution)
    resolution.widget_root = current
    for index = start_index, #path do
        local segment = path[index]
        table.insert(resolution.widget_segments, segment)
        local lookup_ok, child = pcall(self._get_widget, current, segment)
        if not lookup_ok then
            return fail(resolution, M.EFailureKind.WIDGET_LOOKUP_FAILED, {
                index=index,
                segment=segment,
                current_type=safe_type_label(self, current),
                detail=bounded_label(child),
            })
        end
        if child == nil then
            return fail(resolution, M.EFailureKind.MISSING_WIDGET, {
                index=index,
                segment=segment,
                current_type=safe_type_label(self, current),
            })
        end
        current = child
    end
    resolution.widget = current
    return resolution
end

---Captures exact root and final identities for a successful widget result.
---@param self dwarfspec.NativeGameUIPathResolver
---@param resolution dwarfspec.GameUIPathResolution
---@return dwarfspec.GameUIPathResolution
local function capture_identities(self, resolution)
    local root_ok, root_identity =
        pcall(self._identity_of, resolution.widget_root)
    local widget_ok, widget_identity =
        pcall(self._identity_of, resolution.widget)
    if not root_ok or root_identity == nil or
            not widget_ok or widget_identity == nil then
        return fail(resolution, M.EFailureKind.IDENTITY_UNAVAILABLE, {
            current_type=safe_type_label(self, resolution.widget),
            detail=bounded_label(
                not root_ok and root_identity or widget_identity),
        })
    end
    resolution.widget_root_identity = root_identity
    resolution.widget_identity = widget_identity
    return resolution
end

---Resolves one full path from main_interface into an exact native widget.
---@param path dwarfspec.NativePath
---@return dwarfspec.GameUIPathResolution
function NativeGameUIPathResolver:resolve(path)
    local normalized, invalid_index, invalid_segment = normalize_path(path)
    local resolution = new_resolution(normalized or {})
    if not normalized then
        return fail(resolution, M.EFailureKind.INVALID_PATH, {
            index=invalid_index,
            segment=invalid_segment,
        })
    end

    local main_ok, current = pcall(self._get_main_interface)
    if not main_ok or current == nil then
        return fail(
            resolution, M.EFailureKind.MAIN_INTERFACE_UNAVAILABLE, {
                detail=bounded_label(current),
            })
    end

    for index, segment in ipairs(normalized) do
        local current_is_container =
            safe_predicate(self._is_container, current)
        if type(segment) == 'number' then
            if current_is_container then
                resolution = resolve_widgets(
                    self, current, normalized, index, resolution)
                break
            end
            return fail(
                resolution, M.EFailureKind.INVALID_STRUCTURAL_SEGMENT, {
                    index=index,
                    segment=segment,
                    current_type=safe_type_label(self, current),
                })
        end

        local type_descriptor, fields =
            declared_fields(self, current, resolution, index, segment)
        if not type_descriptor then return resolution end
        local metadata = fields[segment]
        if metadata ~= nil then
            local kind = type(metadata) == 'table' and metadata.kind or nil
            if not field_kind_members[kind] or
                    not is_traversable_field(kind) then
                return fail(resolution, M.EFailureKind.UNSUPPORTED_FIELD, {
                    index=index,
                    segment=segment,
                    current_type=bounded_label(type_descriptor),
                    field_kind=field_kind_members[kind] and kind or nil,
                    detail=bounded_label(kind),
                })
            end
            local read_ok, value =
                pcall(self._read_field, current, metadata)
            if not read_ok then
                return fail(
                    resolution, M.EFailureKind.FIELD_ACCESS_FAILED, {
                        index=index,
                        segment=segment,
                        current_type=bounded_label(type_descriptor),
                        field_kind=kind,
                        detail=bounded_label(value),
                    })
            end
            local value_type_ok, value_type =
                pcall(self._get_type, value)
            if not value_type_ok or value_type == nil or
                    (kind == M.EFieldKind.WIDGET and
                        not safe_predicate(self._is_widget, value)) then
                return fail(
                    resolution, M.EFailureKind.UNSUPPORTED_FIELD_VALUE, {
                        index=index,
                        segment=segment,
                        current_type=bounded_label(type_descriptor),
                        field_kind=kind,
                        detail=bounded_label(value_type),
                    })
            end
            table.insert(resolution.structural_segments, segment)
            current = value
        elseif current_is_container then
            resolution = resolve_widgets(
                self, current, normalized, index, resolution)
            break
        else
            local available, omitted = summarize_fields(fields)
            return fail(resolution, M.EFailureKind.MISSING_FIELD, {
                index=index,
                segment=segment,
                current_type=bounded_label(type_descriptor),
                available_fields=available,
                omitted_field_count=omitted,
            })
        end
    end

    if resolution.widget == nil then
        resolution.widget_root = current
        resolution.widget = current
    end
    if not safe_predicate(self._is_widget, resolution.widget) then
        return fail(resolution, M.EFailureKind.FINAL_NOT_WIDGET, {
            index=#normalized,
            segment=normalized[#normalized],
            current_type=safe_type_label(self, resolution.widget),
        })
    end
    return capture_identities(self, resolution)
end

---Creates a structural game-UI path resolver from explicit read-only services.
---@param options table
---@return dwarfspec.NativeGameUIPathResolver
function M.new(options)
    assert(type(options) == 'table',
        'native game-UI path resolver requires dependency options')
    local required = {
        'get_main_interface',
        'get_type',
        'get_fields',
        'read_field',
        'is_widget',
        'is_container',
        'get_widget',
    }
    for _, name in ipairs(required) do
        assert(type(options[name]) == 'function',
            'native game-UI path resolver requires ' .. name)
    end
    local identity_of = options.identity_of
    if identity_of == nil then
        ---Returns the exact object as its default injected identity.
        ---@param value any
        ---@return any
        identity_of = function(value) return value end
    end
    assert(type(identity_of) == 'function',
        'native game-UI path resolver identity_of must be a function')
    return setmetatable({
        _get_main_interface=options.get_main_interface,
        _get_type=options.get_type,
        _get_fields=options.get_fields,
        _read_field=options.read_field,
        _is_widget=options.is_widget,
        _is_container=options.is_container,
        _get_widget=options.get_widget,
        _identity_of=identity_of,
    }, NativeGameUIPathResolver)
end

return M
