-- Validation and stable presentation for base-screen focus diagnostics.

local EComparison =
    require('dwarfspec.protocol.diagnostics.base_screen_focus_comparisons')

local M = {
    CHANGE_KIND='base_screen_focus_changed',
    INCOMPLETE_KIND='base_screen_focus_verification_incomplete',
}

local COMPARISONS = {
    [EComparison.SAME]='same',
    [EComparison.CHANGED]='changed',
    [EComparison.UNAVAILABLE]='unavailable',
}

local SCREEN_STATUSES = {
    present=true,
    none=true,
    unavailable=true,
}

local FOCUS_STATUSES = {
    available=true,
    unavailable=true,
}

---Rejects fields outside one closed diagnostic record contract.
---@param value table
---@param allowed table<string, boolean>
---@param path string
local function require_only_fields(value, allowed, path)
    for field in pairs(value) do
        assert(allowed[field] == true,
            path .. ' has unsupported field: ' .. tostring(field))
    end
end

---Returns whether a value is a positive integer.
---@param value any
---@return boolean
local function is_positive_integer(value)
    return type(value) == 'number' and value > 0 and value % 1 == 0
end

---Requires one nonempty string.
---@param value any
---@param path string
local function require_string(value, path)
    assert(type(value) == 'string' and value ~= '',
        path .. ' must be a nonempty string')
end

---Validates one detached before or after observation.
---@param details table
---@param path string
local function validate_details(details, path)
    assert(type(details) == 'table', path .. ' must be a table')
    require_only_fields(details, {screen=true, focus=true}, path)
    assert(type(details.screen) == 'table',
        path .. '.screen must be a table')
    assert(type(details.focus) == 'table',
        path .. '.focus must be a table')
    require_only_fields(details.screen, {
        status=true, type=true, error=true,
    }, path .. '.screen')
    require_only_fields(details.focus, {
        status=true, values=true, error=true, truncated=true,
    }, path .. '.focus')
    assert(SCREEN_STATUSES[details.screen.status] == true,
        path .. '.screen.status is invalid')
    assert(FOCUS_STATUSES[details.focus.status] == true,
        path .. '.focus.status is invalid')
    assert(type(details.focus.values) == 'table',
        path .. '.focus.values must be a table')

    if details.screen.status == 'present' then
        require_string(details.screen.type, path .. '.screen.type')
        assert(not details.screen.type:match('0[xX][0-9a-fA-F]+'),
            path .. '.screen.type must not contain an address')
        assert(details.screen.error == nil,
            path .. '.screen.error must be absent when present')
    elseif details.screen.status == 'none' then
        assert(details.screen.type == nil and details.screen.error == nil,
            path .. '.screen must have no type or error when none')
    else
        assert(details.screen.type == nil,
            path .. '.screen.type must be absent when unavailable')
        require_string(details.screen.error, path .. '.screen.error')
    end
    if details.focus.status == 'available' then
        assert(details.focus.error == nil and
            details.focus.truncated == nil,
            path .. '.focus cannot have failure metadata when available')
    else
        require_string(details.focus.error, path .. '.focus.error')
    end
    if details.focus.truncated ~= nil then
        assert(type(details.focus.truncated) == 'boolean',
            path .. '.focus.truncated must be boolean')
    end
    local count = 0
    local maximum = 0
    for key, value in pairs(details.focus.values) do
        assert(type(key) == 'number' and key >= 1 and key % 1 == 0,
            path .. '.focus.values must be an array')
        assert(type(value) == 'string',
            ('%s.focus.values[%s] must be a string')
                :format(path, tostring(key)))
        count = count + 1
        maximum = math.max(maximum, key)
    end
    assert(count == maximum,
        path .. '.focus.values must be a dense array')
    for index, value in ipairs(details.focus.values) do
        assert(type(value) == 'string',
            ('%s.focus.values[%d] must be a string'):format(path, index))
    end
end

---Validates lifecycle identity fields shared by focus diagnostics.
---@param content table
---@param path string
local function validate_identity(content, path)
    require_only_fields(content, {
        severity=true,
        scope=true,
        attribution=true,
        suite_name=true,
        example_name=true,
        source_identity=true,
        repeat_index=true,
        screen_comparison=true,
        focus_comparison=true,
        details_complete=true,
        before=true,
        after=true,
    }, path)
    assert(content.scope == 'example' or content.scope == 'suite',
        path .. '.scope must be example or suite')
    require_string(content.suite_name, path .. '.suite_name')
    assert(is_positive_integer(content.repeat_index),
        path .. '.repeat_index must be a positive integer')
    if content.source_identity ~= nil then
        require_string(content.source_identity, path .. '.source_identity')
    end

    if content.scope == 'suite' then
        assert(content.attribution == 'file',
            path .. '.attribution must be file for suite scope')
        assert(content.example_name == nil,
            path .. '.example_name is not valid for suite scope')
    else
        assert(content.attribution == 'test' or
            content.attribution == 'before_each',
            path .. '.attribution is invalid for example scope')
        if content.attribution == 'test' then
            require_string(content.example_name, path .. '.example_name')
        else
            assert(content.example_name == nil,
                path .. '.example_name must be absent for before_each')
        end
    end
end

---Validates one new base-screen focus diagnostic payload.
---@param diagnostic table
---@param path string|nil
---@return table
function M.validate(diagnostic, path)
    path = path or 'focus diagnostic'
    assert(type(diagnostic) == 'table', path .. ' must be a table')
    require_only_fields(diagnostic, {kind=true, content=true}, path)
    assert(diagnostic.kind == M.CHANGE_KIND or
        diagnostic.kind == M.INCOMPLETE_KIND,
        path .. '.kind is unsupported')
    local content = diagnostic.content
    assert(type(content) == 'table', path .. '.content must be a table')
    validate_identity(content, path .. '.content')

    local screen = content.screen_comparison
    local focus = content.focus_comparison
    assert(COMPARISONS[screen] ~= nil,
        path .. '.content.screen_comparison is invalid')
    assert(COMPARISONS[focus] ~= nil,
        path .. '.content.focus_comparison is invalid')
    assert(type(content.details_complete) == 'boolean',
        path .. '.content.details_complete must be boolean')
    local complete = screen ~= EComparison.UNAVAILABLE and
        focus ~= EComparison.UNAVAILABLE
    assert(content.details_complete == complete,
        path .. '.content.details_complete does not match comparisons')

    if diagnostic.kind == M.CHANGE_KIND then
        assert(content.severity == 'warning',
            path .. '.content.severity must be warning')
        assert(screen == EComparison.CHANGED or
            focus == EComparison.CHANGED,
            path .. ' must contain an affirmative change')
    else
        assert(content.severity == 'info',
            path .. '.content.severity must be info')
        assert(screen ~= EComparison.CHANGED and
            focus ~= EComparison.CHANGED,
            path .. ' must not contain an affirmative change')
        assert(not complete,
            path .. ' must contain unavailable verification')
    end

    validate_details(content.before, path .. '.content.before')
    validate_details(content.after, path .. '.content.after')
    local screen_available =
        content.before.screen.status ~= 'unavailable' and
        content.after.screen.status ~= 'unavailable'
    local focus_available =
        content.before.focus.status ~= 'unavailable' and
        content.after.focus.status ~= 'unavailable'
    assert((screen ~= EComparison.UNAVAILABLE) == screen_available,
        path .. '.content.screen_comparison does not match observations')
    assert((focus ~= EComparison.UNAVAILABLE) == focus_available,
        path .. '.content.focus_comparison does not match observations')
    return diagnostic
end

return M
