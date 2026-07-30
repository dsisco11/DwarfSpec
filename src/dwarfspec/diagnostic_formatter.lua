-- Deterministic one-line CLI diagnostic rendering for DwarfSpec problems.

local ErrorFormat = require('dwarfspec.error_formats')

---@class DwarfSpecDiagnosticFormatter
local M = {}

local MSBUILD_CODES = {
    failure='DS1001',
    error='DS1002',
}

---Returns whether one value is a supported immutable error-format value.
---@param value any
---@return boolean
local function is_error_format(value)
    for _, candidate in pairs(ErrorFormat) do
        if value == candidate then return true end
    end
    return false
end

---Returns whether one number is a positive integer.
---@param value any
---@return boolean
local function is_positive_integer(value)
    return type(value) == 'number' and value > 0 and value % 1 == 0
end

---Removes ANSI escape sequences without interpreting display contents.
---@param value string
---@return string
local function remove_ansi(value)
    local output = {}
    local index = 1
    while index <= #value do
        local byte = value:byte(index)
        if byte ~= 27 then
            output[#output + 1] = value:sub(index, index)
            index = index + 1
        else
            local introducer = value:byte(index + 1)
            if introducer == 91 then
                index = index + 2
                while index <= #value do
                    local candidate = value:byte(index)
                    index = index + 1
                    if candidate >= 64 and candidate <= 126 then break end
                end
            elseif introducer == 93 then
                index = index + 2
                while index <= #value do
                    local candidate = value:byte(index)
                    if candidate == 7 then
                        index = index + 1
                        break
                    end
                    if candidate == 27 and value:byte(index + 1) == 92 then
                        index = index + 2
                        break
                    end
                    index = index + 1
                end
            else
                index = index + (introducer == nil and 1 or 2)
            end
        end
    end
    return table.concat(output)
end

---Creates a safe single-line copy of one displayed field.
---@param value string
---@return string
local function sanitize(value)
    local stripped = remove_ansi(value)
    local output = {}
    local replacing_controls = false
    for index = 1, #stripped do
        local byte = stripped:byte(index)
        local is_control = byte <= 31 or byte == 127
        if is_control then
            if output[#output] ~= ' ' then output[#output + 1] = ' ' end
            replacing_controls = true
        elseif byte == 32 and replacing_controls then
            -- The preceding replacement already safely separates the fields.
        else
            output[#output + 1] = stripped:sub(index, index)
            replacing_controls = false
        end
    end
    if replacing_controls and output[#output] == ' ' then
        output[#output] = nil
    end
    return table.concat(output)
end

---Returns a canonical slash-separated path.
---@param value string
---@return string
local function canonical_path(value)
    local normalized = value:gsub('\\', '/'):gsub('/+', '/')
    if normalized ~= '/' then normalized = normalized:gsub('/+$', '') end
    return normalized
end

---Returns whether one source identity is a safe project-relative path.
---@param value any
---@return boolean
local function is_relative_identity(value)
    if type(value) ~= 'string' or value == '' then return false end
    local normalized = value:gsub('\\', '/')
    if normalized:sub(1, 1) == '/' or
            normalized:match('^[A-Za-z]:/') then
        return false
    end
    for segment in normalized:gmatch('[^/]+') do
        if segment == '.' or segment == '..' then return false end
    end
    return true
end

---Returns whether one problem has a trustworthy matchable location.
---@param problem table
---@return boolean
local function has_location(problem)
    return is_relative_identity(problem.source_identity) and
        is_positive_integer(problem.line) and
        (problem.column == nil or is_positive_integer(problem.column))
end

---Resolves one canonical source identity against its absolute project root.
---@param project_root string
---@param source_identity string
---@return string
local function absolute_source(project_root, source_identity)
    local root = canonical_path(project_root)
    local source = canonical_path(source_identity):gsub('^/+', '')
    return root == '/' and '/' .. source or root .. '/' .. source
end

---Builds the sanitized problem message shared by all standard formats.
---@param problem table
---@return string
local function diagnostic_message(problem)
    return sanitize(problem.name) .. ': ' .. sanitize(problem.message)
end

---Renders one problem in the existing human-readable fallback shape.
---@param problem table
---@return string
local function human_fallback(problem)
    return ('%s %s'):format(
        sanitize(problem.kind):upper(), diagnostic_message(problem))
end

---Renders one matchable problem in MSBuild format.
---@param project_root string
---@param problem table
---@return string
local function msbuild(project_root, problem)
    local source = absolute_source(project_root, problem.source_identity)
    if source:match('^[A-Za-z]:/') then source = source:gsub('/', '\\') end
    return ('%s(%d,%d): error %s: %s'):format(
        sanitize(source), problem.line, problem.column or 1,
        MSBUILD_CODES[problem.kind], diagnostic_message(problem))
end

---Renders one matchable problem in GCC or Clang format.
---@param project_root string
---@param problem table
---@return string
local function gcc(project_root, problem)
    return ('%s:%d:%d: error: %s'):format(
        sanitize(absolute_source(project_root, problem.source_identity)),
        problem.line, problem.column or 1, diagnostic_message(problem))
end

---Renders one matchable problem in ESLint Compact format.
---@param problem table
---@return string
local function eslint(problem)
    return ('%s: line %d, col %d, Error - %s (dwarfspec)'):format(
        sanitize(canonical_path(problem.source_identity)),
        problem.line, problem.column or 1, diagnostic_message(problem))
end

---Renders one structured problem in the selected external CLI format.
---@param error_format DwarfSpecErrorFormat
---@param project_root string
---@param problem table
---@return string
function M.format(error_format, project_root, problem)
    assert(is_error_format(error_format),
        'diagnostic error format is unsupported: ' .. tostring(error_format))
    assert(type(project_root) == 'string' and project_root ~= '',
        'diagnostic project root must be a nonempty string')
    assert(project_root:match('^[/\\]') or
        project_root:match('^[A-Za-z]:[/\\]'),
        'diagnostic project root must be absolute')
    assert(type(problem) == 'table',
        'diagnostic problem must be a table')
    assert(MSBUILD_CODES[problem.kind] ~= nil,
        'diagnostic problem kind is unsupported: ' .. tostring(problem.kind))
    assert(type(problem.name) == 'string' and problem.name ~= '',
        'diagnostic problem name must be a nonempty string')
    assert(type(problem.message) == 'string',
        'diagnostic problem message must be a string')

    if not has_location(problem) then return human_fallback(problem) end
    if error_format == ErrorFormat.MSBUILD then
        return msbuild(project_root, problem)
    end
    if error_format == ErrorFormat.GCC then
        return gcc(project_root, problem)
    end
    return eslint(problem)
end

return M
