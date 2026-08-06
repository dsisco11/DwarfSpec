-- Finite timeout resolution and bounded legacy compatibility diagnostics.

local settings_validator =
    require('dwarfspec.protocol.configuration.settings')

---@class dwarfspec.TimeoutResolution
---@field timeout_ms integer
---@field source string
---@field diagnostics table[]
---@field legacy_unlimited boolean

---@class dwarfspec.TimeoutPolicy
---@field _framework_command_timeout_ms integer
---@field _framework_cleanup_timeout_ms integer
local TimeoutPolicy = {}
TimeoutPolicy.__index = TimeoutPolicy

---Validates one positive finite integer timeout.
---@param value any
---@param label string
---@return integer
function TimeoutPolicy:_positive_timeout(value, label)
    assert(type(value) == 'number' and value >= 1 and value % 1 == 0 and
        value < math.huge,
        label .. ' must be a positive finite integer')
    return value
end

---Returns one bounded immutable-style deprecation diagnostic.
---@param code string
---@param message string
---@return table
function TimeoutPolicy:_deprecation(code, message)
    return {kind='deprecation', code=code, message=message}
end

---Creates a timeout policy with finite framework defaults.
---@param options table|nil
---@return dwarfspec.TimeoutPolicy
function TimeoutPolicy.new(options)
    options = options or {}
    local instance = setmetatable({}, TimeoutPolicy)
    instance._framework_command_timeout_ms = instance:_positive_timeout(
        options.command_timeout_ms or
            settings_validator.default_command_timeout_ms,
        'framework command timeout')
    instance._framework_cleanup_timeout_ms = instance:_positive_timeout(
        options.cleanup_timeout_ms or
            settings_validator.default_cleanup_timeout_ms,
        'framework cleanup timeout')
    return instance
end

---Resolves command timeout precedence and the bounded compatibility window.
---@param invocation_timeout_ms integer|false|nil
---@param settings table|nil
---@param definition_timeout_ms integer|nil
---@param run_lease_remaining_ms integer|nil
---@param legacy_wait_compatibility boolean|nil
---@return dwarfspec.TimeoutResolution
function TimeoutPolicy:resolve_command(invocation_timeout_ms, settings,
        definition_timeout_ms, run_lease_remaining_ms,
        legacy_wait_compatibility)
    settings = settings or {}
    local command = settings.command or {}
    local wait = settings.wait or {}
    local diagnostics = {}
    if wait.timeout_ms ~= nil then
        self:_positive_timeout(wait.timeout_ms,
            'settings.wait.timeout_ms')
        diagnostics[#diagnostics + 1] = self:_deprecation(
            'settings_wait_timeout_ms',
            'settings.wait.timeout_ms is deprecated; use ' ..
                'settings.command.timeout_ms')
    end
    if invocation_timeout_ms == false then
        assert(legacy_wait_compatibility == true,
            'timeout_ms=false is limited to legacy wait commands')
        local lease = self:_positive_timeout(run_lease_remaining_ms,
            'legacy unlimited command run lease')
        diagnostics[#diagnostics + 1] = self:_deprecation(
            'command_timeout_false',
            'timeout_ms=false is deprecated and bounded by the run lease')
        return {
            timeout_ms=lease,
            source='run_lease',
            diagnostics=diagnostics,
            legacy_unlimited=true,
        }
    end
    if invocation_timeout_ms ~= nil then
        return {
            timeout_ms=self:_positive_timeout(invocation_timeout_ms,
                'command invocation timeout'),
            source='invocation', diagnostics=diagnostics,
            legacy_unlimited=false,
        }
    end
    if command.timeout_ms ~= nil then
        return {
            timeout_ms=self:_positive_timeout(command.timeout_ms,
                'settings.command.timeout_ms'),
            source='project', diagnostics=diagnostics,
            legacy_unlimited=false,
        }
    end
    if wait.timeout_ms ~= nil then
        return {
            timeout_ms=wait.timeout_ms, source='legacy_wait',
            diagnostics=diagnostics, legacy_unlimited=false,
        }
    end
    if definition_timeout_ms ~= nil then
        return {
            timeout_ms=self:_positive_timeout(definition_timeout_ms,
                'command definition timeout'),
            source='definition', diagnostics=diagnostics,
            legacy_unlimited=false,
        }
    end
    return {
        timeout_ms=self._framework_command_timeout_ms,
        source='framework', diagnostics=diagnostics,
        legacy_unlimited=false,
    }
end

---Resolves cleanup timeout precedence without an unlimited form.
---@param registration_timeout_ms integer|nil
---@param settings table|nil
---@return dwarfspec.TimeoutResolution
function TimeoutPolicy:resolve_cleanup(registration_timeout_ms, settings)
    settings = settings or {}
    local cleanup = settings.cleanup or {}
    if registration_timeout_ms ~= nil then
        return {
            timeout_ms=self:_positive_timeout(registration_timeout_ms,
                'cleanup registration timeout'),
            source='registration', diagnostics={}, legacy_unlimited=false,
        }
    end
    if cleanup.timeout_ms ~= nil then
        return {
            timeout_ms=self:_positive_timeout(cleanup.timeout_ms,
                'settings.cleanup.timeout_ms'),
            source='project', diagnostics={}, legacy_unlimited=false,
        }
    end
    return {
        timeout_ms=self._framework_cleanup_timeout_ms,
        source='framework', diagnostics={}, legacy_unlimited=false,
    }
end

return TimeoutPolicy
