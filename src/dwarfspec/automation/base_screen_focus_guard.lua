-- Detached base-game screen and focus observations for pollution detection.

local EComparison =
    require('dwarfspec.automation.base_screen_focus_comparisons')

local M = {}

local DEFAULT_MAX_ERROR_BYTES = 512
local DEFAULT_MAX_FOCUS_COUNT = 64
local DEFAULT_MAX_FOCUS_STRING_BYTES = 256
local DEFAULT_MAX_SCREEN_LABEL_BYTES = 128

---@class BaseScreenFocusGuardOptions
---@field max_error_bytes integer|nil
---@field max_focus_count integer|nil
---@field max_focus_string_bytes integer|nil
---@field max_screen_label_bytes integer|nil

---@class BaseScreenFocusScreenDetails
---@field status 'present'|'none'|'unavailable'
---@field type string|nil
---@field error string|nil

---@class BaseScreenFocusFocusDetails
---@field status 'available'|'unavailable'
---@field values string[]
---@field error string|nil
---@field truncated boolean|nil

---@class BaseScreenFocusDetails
---@field screen BaseScreenFocusScreenDetails
---@field focus BaseScreenFocusFocusDetails

---@class BaseScreenFocusPrivateScreen
---@field status 'present'|'none'|'unavailable'
---@field identity any

---@class BaseScreenFocusPrivateFocus
---@field status 'available'|'unavailable'
---@field set table<string, boolean>|nil

---@class BaseScreenFocusObservation
---@field private {screen: BaseScreenFocusPrivateScreen, focus: BaseScreenFocusPrivateFocus}
---@field details BaseScreenFocusDetails
---@field _guard_tag table

---@class BaseScreenFocusComparison
---@field severity 'warning'|'info'
---@field screen_comparison DwarfSpecEBaseScreenFocusComparison
---@field focus_comparison DwarfSpecEBaseScreenFocusComparison
---@field details_complete boolean
---@field before BaseScreenFocusDetails
---@field after BaseScreenFocusDetails

---@class BaseScreenFocusDiagnostic
---@field kind 'base_screen_focus_changed'|'base_screen_focus_verification_incomplete'
---@field content BaseScreenFocusComparison

---@class BaseScreenFocusGuard
---@field capture fun(self: BaseScreenFocusGuard): BaseScreenFocusObservation
---@field compare fun(self: BaseScreenFocusGuard, before: BaseScreenFocusObservation, after: BaseScreenFocusObservation): BaseScreenFocusDiagnostic|nil

---Returns whether a value is a positive integer.
---@param value any
---@return boolean
local function is_positive_integer(value)
    return type(value) == 'number' and value > 0 and value % 1 == 0
end

---Returns one validated positive bound.
---@param options BaseScreenFocusGuardOptions
---@param name string
---@param fallback integer
---@return integer
local function bound(options, name, fallback)
    local value = options[name] or fallback
    assert(is_positive_integer(value),
        'base-screen focus guard ' .. name .. ' must be a positive integer')
    return value
end

---Returns a printable representation without allowing tostring to escape.
---@param value any
---@return string
local function safe_text(value)
    local ok, result = pcall(tostring, value)
    if not ok then return '<unprintable>' end
    return result
end

---Returns text shortened to one maximum byte count.
---@param value any
---@param maximum integer
---@return string
local function bounded_text(value, maximum)
    local text = safe_text(value)
    if #text <= maximum then return text end
    if maximum <= 3 then return text:sub(1, maximum) end
    return text:sub(1, maximum - 3) .. '...'
end

---Returns a stable screen class label without stringifying the screen.
---@param screen any
---@param maximum integer
---@return string
local function screen_label(screen, maximum)
    local ok, result = pcall(function()
        local type_value = screen._type
        if type(type_value) == 'string' and type_value ~= '' then
            return type_value
        end
        if type(type_value) == 'table' then
            local name = type_value._name or type_value.name
            if type(name) == 'string' and name ~= '' then return name end
        end
        return type(screen)
    end)
    local label = ok and result or type(screen)
    label = label:gsub('0[xX][0-9a-fA-F]+', '<address>')
    return bounded_text(label, maximum)
end

---Returns unavailable focus details and its private comparison state.
---@param message any
---@param limits table
---@param values string[]|nil
---@param truncated boolean|nil
---@return table, BaseScreenFocusPrivateFocus
local function unavailable_focus(message, limits, values, truncated)
    return {
        status='unavailable',
        values=values or {},
        error=bounded_text(message, limits.max_error_bytes),
        truncated=truncated or nil,
    }, {
        status='unavailable',
        set=nil,
    }
end

---Copies and canonicalizes one DFHack-owned focus string table.
---@param source any
---@param limits table
---@return table, BaseScreenFocusPrivateFocus
local function copy_focus(source, limits)
    if type(source) ~= 'table' then
        return unavailable_focus(
            'DFHack getFocusStrings did not return a table', limits)
    end

    local ok, details, private = xpcall(function()
        local count = 0
        local maximum = 0
        for key in pairs(source) do
            if type(key) ~= 'number' or key < 1 or key % 1 ~= 0 then
                error('DFHack getFocusStrings returned a non-array table', 0)
            end
            count = count + 1
            maximum = math.max(maximum, key)
        end
        if maximum ~= count then
            error('DFHack getFocusStrings returned a sparse array', 0)
        end

        local values = {}
        local copied_count = math.min(count, limits.max_focus_count)
        for index = 1, copied_count do
            local value = source[index]
            if type(value) ~= 'string' then
                return unavailable_focus(
                    'DFHack getFocusStrings returned a non-string value',
                    limits, values)
            end
            if #value > limits.max_focus_string_bytes then
                table.insert(values,
                    bounded_text(value, limits.max_focus_string_bytes))
                return unavailable_focus(
                    'DFHack focus string exceeded the configured byte limit',
                    limits, values, true)
            end
            table.insert(values, value)
        end
        if count > limits.max_focus_count then
            return unavailable_focus(
                'DFHack focus list exceeded the configured entry limit',
                limits, values, true)
        end

        local canonical = {}
        for _, value in ipairs(values) do canonical[value] = true end
        return {
            status='available',
            values=values,
        }, {
            status='available',
            set=canonical,
        }
    end, function(failure) return safe_text(failure) end)
    if not ok then return unavailable_focus(details, limits) end
    return details, private
end

---Captures focus details for one successfully resolved base screen state.
---@param gui table
---@param screen_status 'present'|'none'
---@param screen any
---@param limits table
---@return table, BaseScreenFocusPrivateFocus
local function capture_focus(gui, screen_status, screen, limits)
    if screen_status == 'none' then
        return {
            status='available',
            values={},
        }, {
            status='available',
            set={},
        }
    end

    local ok, source = pcall(gui.getFocusStrings, screen)
    if not ok then return unavailable_focus(source, limits) end
    return copy_focus(source, limits)
end

---Returns a detached copy of one observation's diagnostic details.
---@param source BaseScreenFocusDetails
---@return BaseScreenFocusDetails
local function copy_details(source)
    local screen = {
        status=source.screen.status,
        type=source.screen.type,
        error=source.screen.error,
    }
    local values = {}
    for index, value in ipairs(source.focus.values) do values[index] = value end
    return {
        screen=screen,
        focus={
            status=source.focus.status,
            values=values,
            error=source.focus.error,
            truncated=source.focus.truncated,
        },
    }
end

---Compares exact private base-screen states.
---@param before BaseScreenFocusPrivateScreen
---@param after BaseScreenFocusPrivateScreen
---@return DwarfSpecEBaseScreenFocusComparison
local function compare_screen(before, after)
    if before.status == 'unavailable' or after.status == 'unavailable' then
        return EComparison.UNAVAILABLE
    end
    if before.status ~= after.status then return EComparison.CHANGED end
    if before.status == 'none' then return EComparison.SAME end
    local ok, same = pcall(function()
        return before.identity == after.identity
    end)
    if not ok then return EComparison.UNAVAILABLE end
    return same and EComparison.SAME or EComparison.CHANGED
end

---Returns whether two canonical string sets have identical membership.
---@param before table<string, boolean>
---@param after table<string, boolean>
---@return boolean
local function same_set(before, after)
    for value in pairs(before) do
        if not after[value] then return false end
    end
    for value in pairs(after) do
        if not before[value] then return false end
    end
    return true
end

---Compares private canonical focus states.
---@param before BaseScreenFocusPrivateFocus
---@param after BaseScreenFocusPrivateFocus
---@return DwarfSpecEBaseScreenFocusComparison
local function compare_focus(before, after)
    if before.status == 'unavailable' or after.status == 'unavailable' then
        return EComparison.UNAVAILABLE
    end
    return same_set(before.set, after.set) and
        EComparison.SAME or EComparison.CHANGED
end

---Creates an isolated base-screen focus guard over injected DFHack GUI APIs.
---@param gui table
---@param options BaseScreenFocusGuardOptions|nil
---@return BaseScreenFocusGuard
function M.new(gui, options)
    assert(type(gui) == 'table',
        'base-screen focus guard GUI dependencies must be a table')
    assert(type(gui.getDFViewscreen) == 'function',
        'base-screen focus guard requires getDFViewscreen')
    assert(type(gui.getFocusStrings) == 'function',
        'base-screen focus guard requires getFocusStrings')
    options = options or {}
    assert(type(options) == 'table',
        'base-screen focus guard options must be a table')

    local limits = {
        max_error_bytes=bound(
            options, 'max_error_bytes', DEFAULT_MAX_ERROR_BYTES),
        max_focus_count=bound(
            options, 'max_focus_count', DEFAULT_MAX_FOCUS_COUNT),
        max_focus_string_bytes=bound(
            options, 'max_focus_string_bytes',
            DEFAULT_MAX_FOCUS_STRING_BYTES),
        max_screen_label_bytes=bound(
            options, 'max_screen_label_bytes',
            DEFAULT_MAX_SCREEN_LABEL_BYTES),
    }
    local guard_tag = {}
    local guard = {}

    ---Captures one private comparison token and detached diagnostic record.
    ---@return BaseScreenFocusObservation
    function guard:capture()
        local screen_ok, screen = pcall(gui.getDFViewscreen, true)
        if not screen_ok then
            local message = bounded_text(screen, limits.max_error_bytes)
            return {
                private={
                    screen={status='unavailable'},
                    focus={status='unavailable'},
                },
                details={
                    screen={
                        status='unavailable',
                        error=message,
                    },
                    focus={
                        status='unavailable',
                        values={},
                        error=message,
                    },
                },
                _guard_tag=guard_tag,
            }
        end

        local screen_status = screen == nil and 'none' or 'present'
        local focus_details, focus_private = capture_focus(
            gui, screen_status, screen, limits)
        return {
            private={
                screen={
                    status=screen_status,
                    identity=screen,
                },
                focus=focus_private,
            },
            details={
                screen={
                    status=screen_status,
                    type=screen ~= nil and
                        screen_label(screen, limits.max_screen_label_bytes) or
                        nil,
                },
                focus=focus_details,
            },
            _guard_tag=guard_tag,
        }
    end

    ---Compares two observations and returns only an actionable diagnostic.
    ---@param before BaseScreenFocusObservation
    ---@param after BaseScreenFocusObservation
    ---@return BaseScreenFocusDiagnostic|nil
    function guard:compare(before, after)
        assert(type(before) == 'table' and before._guard_tag == guard_tag,
            'before observation belongs to a different focus guard')
        assert(type(after) == 'table' and after._guard_tag == guard_tag,
            'after observation belongs to a different focus guard')

        local screen_comparison = compare_screen(
            before.private.screen, after.private.screen)
        local focus_comparison = compare_focus(
            before.private.focus, after.private.focus)
        if screen_comparison == EComparison.SAME and
                focus_comparison == EComparison.SAME then
            return nil
        end

        local changed = screen_comparison == EComparison.CHANGED or
            focus_comparison == EComparison.CHANGED
        local content = {
            severity=changed and 'warning' or 'info',
            screen_comparison=screen_comparison,
            focus_comparison=focus_comparison,
            details_complete=screen_comparison ~= EComparison.UNAVAILABLE and
                focus_comparison ~= EComparison.UNAVAILABLE,
            before=copy_details(before.details),
            after=copy_details(after.details),
        }
        return {
            kind=changed and 'base_screen_focus_changed' or
                'base_screen_focus_verification_incomplete',
            content=content,
        }
    end

    return guard
end

return M
