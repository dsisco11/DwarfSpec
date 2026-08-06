-- Shared validation for external and in-process project settings.

local ErrorFormat = require('dwarfspec.protocol.configuration.error_formats')
local glob = require('dwarfspec.support.glob')

local M = {
    default_error_format=ErrorFormat.MSBUILD,
    default_command_timeout_ms=10000,
    default_cleanup_timeout_ms=10000,
}

---Returns whether a value is a supported immutable error format.
---@param value any
---@return boolean
local function is_error_format(value)
    for _, candidate in pairs(ErrorFormat) do
        if value == candidate then return true end
    end
    return false
end

---Validates one positive integer setting when it is present.
---@param value any
---@param label string
local function optional_positive_integer(value, label)
    if value == nil then return end
    assert(type(value) == 'number' and value >= 1 and value % 1 == 0 and
        value < math.huge,
        label .. ' must be a positive integer')
end

---Validates and copies all supported project settings.
---@param value any
---@param source string
---@return table
function M.validate(value, source)
    if value == nil then value = {} end
    assert(type(value) == 'table', source .. ': settings must be a table')
    for key in pairs(value) do
        assert(key == 'wait' or key == 'command' or key == 'cleanup' or
            key == 'discovery' or key == 'error_format',
            source .. ': unknown setting: ' .. tostring(key))
    end

    local command = value.command or {}
    assert(type(command) == 'table',
        source .. ': settings.command must be a table')
    for key in pairs(command) do
        assert(key == 'timeout_ms',
            source .. ': unknown settings.command field: ' .. tostring(key))
    end
    optional_positive_integer(command.timeout_ms,
        source .. ': settings.command.timeout_ms')

    local cleanup = value.cleanup or {}
    assert(type(cleanup) == 'table',
        source .. ': settings.cleanup must be a table')
    for key in pairs(cleanup) do
        assert(key == 'timeout_ms',
            source .. ': unknown settings.cleanup field: ' .. tostring(key))
    end
    optional_positive_integer(cleanup.timeout_ms,
        source .. ': settings.cleanup.timeout_ms')

    local wait = value.wait or {}
    assert(type(wait) == 'table', source .. ': settings.wait must be a table')
    for key in pairs(wait) do
        assert(key == 'frame_budget' or key == 'timeout_ms',
            source .. ': unknown wait setting: ' .. tostring(key))
    end
    optional_positive_integer(wait.frame_budget,
        source .. ': settings.wait.frame_budget')
    optional_positive_integer(wait.timeout_ms,
        source .. ': settings.wait.timeout_ms')

    local discovery = value.discovery or {}
    assert(type(discovery) == 'table', source ..
        ': settings.discovery must be a table')
    for key in pairs(discovery) do
        assert(key == 'test_glob', source ..
            ': unknown discovery setting: ' .. tostring(key))
    end
    assert(discovery.test_glob == nil or
        type(discovery.test_glob) == 'string' and
        discovery.test_glob ~= '', source ..
        ': settings.discovery.test_glob must be a nonempty string')
    if discovery.test_glob ~= nil then glob.compile(discovery.test_glob) end

    local error_format = value.error_format
    if error_format == nil then error_format = M.default_error_format end
    assert(type(error_format) == 'string', source ..
        ': settings.error_format must be a string')
    assert(error_format ~= '', source ..
        ': settings.error_format must be a nonempty string')
    assert(is_error_format(error_format), source ..
        ': settings.error_format must be one of: msbuild, gcc, eslint')

    return {
        command={
            timeout_ms=command.timeout_ms,
        },
        cleanup={
            timeout_ms=cleanup.timeout_ms,
        },
        wait={
            frame_budget=wait.frame_budget,
            timeout_ms=wait.timeout_ms,
        },
        discovery={
            test_glob=discovery.test_glob,
        },
        error_format=error_format,
    }
end

return M
