-- Structural validation and immutable snapshots for command definitions.

local CleanupLifetime = require('dwarfspec.protocol.enums.cleanup_lifetimes')
local CommandKind = require('dwarfspec.protocol.enums.command_kinds')
local IntrinsicKind = require(
    'dwarfspec.protocol.enums.intrinsic_verification_kinds')
local RetryPolicy = require(
    'dwarfspec.protocol.enums.execution_retry_policies')

---@class dwarfspec.CommandDefinitionValidator
local Definition = {}
local VALIDATED = setmetatable({}, {__mode='k'})

---@class dwarfspec.driver.command.DefinitionInternals
local Internals = {}

---Returns whether a value occurs in an immutable enum.
---@param enum table
---@param value any
---@return boolean
function Internals.enum_contains(enum, value)
    for _, candidate in pairs(enum) do
        if candidate == value then return true end
    end
    return false
end

---Copies a definition tree into recursively immutable proxies.
---@param value any
---@param copies? table
---@return any
function Internals.freeze(value, copies)
    if type(value) ~= 'table' then return value end
    copies = copies or {}
    assert(copies[value] == nil, 'command definition tables must be acyclic')
    copies[value] = true
    local data = {}
    for key, entry in pairs(value) do
        data[key] = Internals.freeze(entry, copies)
    end
    copies[value] = nil
    return setmetatable({}, {
        __index=data,
        __newindex=function()
            error('command definition is immutable', 2)
        end,
        __pairs=function() return pairs(data) end,
        __len=function() return #data end,
        __metatable=false,
    })
end

---Validates an optional positive finite timeout.
---@param timeout_ms any
---@param label string
function Internals.optional_timeout(timeout_ms, label)
    if timeout_ms == nil then return end
    assert(type(timeout_ms) == 'number' and timeout_ms >= 1 and
        timeout_ms % 1 == 0 and timeout_ms < math.huge,
        label .. ' must be a positive finite integer')
end

---Returns the length of a nonempty contiguous array.
---@param value table
---@param label string
---@return integer
function Internals.array_length(value, label)
    local count = 0
    local greatest_index = 0
    for index in pairs(value) do
        assert(type(index) == 'number' and index >= 1 and index % 1 == 0,
            label .. ' must contain only positive integer indexes')
        count = count + 1
        greatest_index = math.max(greatest_index, index)
    end
    assert(count >= 1 and count == greatest_index,
        label .. ' must be a nonempty contiguous array')
    return count
end

---Validates intrinsic verification fields against command behavior.
---@param value table
---@param label string
function Internals.verification(value, label)
    assert(Internals.enum_contains(IntrinsicKind,
        value.intrinsic_verification),
        label .. ' has unsupported intrinsic_verification')
    if value.kind == CommandKind.QUERY or
            value.kind == CommandKind.ASSERTION then
        assert(value.intrinsic_verification ==
            IntrinsicKind.PRIMARY_OBSERVATION,
            label .. ' read-only kinds require primary_observation')
    elseif value.kind ~= CommandKind.WORKFLOW then
        assert(value.intrinsic_verification ~=
            IntrinsicKind.PRIMARY_OBSERVATION,
            label .. ' mutating kinds cannot use primary_observation')
    end
    if value.intrinsic_verification == IntrinsicKind.CALLBACK then
        assert(type(value.verify) == 'function',
            label .. ' callback verification requires verify')
    else
        assert(value.verify == nil,
            label .. ' verify is allowed only for callback verification')
    end
end

---Validates execution retry fields.
---@param value table
---@param label string
function Internals.retry(value, label)
    assert(Internals.enum_contains(RetryPolicy,
        value.execution_retry_policy),
        label .. ' has unsupported execution_retry_policy')
    if value.execution_retry_policy == RetryPolicy.EXPLICIT_RETRY_SAFE then
        assert(type(value.operation_key) == 'function',
            label .. ' explicit_retry_safe requires operation_key')
        assert(value.kind ~= CommandKind.QUERY and
            value.kind ~= CommandKind.ASSERTION,
            label .. ' read-only observations cannot retry execution')
    else
        assert(value.operation_key == nil,
            label .. ' once policy must omit operation_key')
    end
end

---Validates effect and cleanup policy fields.
---@param value table
---@param label string
function Internals.cleanup(value, label)
    local cannot_produce_effect = value.kind == CommandKind.QUERY or
        value.kind == CommandKind.ASSERTION or
        value.kind == CommandKind.WORKFLOW
    if value.cleanup == nil then
        assert(value.claims == nil,
            label .. ' claims require a cleanup policy')
        return
    end
    assert(not cannot_produce_effect,
        label .. ' kind cannot own a cleanup policy')
    assert(type(value.cleanup) == 'table',
        label .. ' cleanup must be a table')
    assert(Internals.enum_contains(CleanupLifetime, value.cleanup.lifetime),
        label .. ' cleanup has unsupported lifetime')
    assert(type(value.cleanup.restore) == 'function',
        label .. ' cleanup requires restore')
    assert(type(value.cleanup.verify) == 'function',
        label .. ' cleanup requires verify')
    assert(value.cleanup.resources == nil or
        type(value.cleanup.resources) == 'function',
        label .. ' cleanup resources must be callable')
    assert(value.cleanup.allow_cross_owner_consumption == nil or
        type(value.cleanup.allow_cross_owner_consumption) == 'boolean',
        label .. ' cleanup allow_cross_owner_consumption must be boolean')
end

---Validates one non-workflow definition or workflow step.
---@param value table
---@param label string
---@param is_step boolean
function Internals.executable(value, label, is_step)
    assert(Internals.enum_contains(CommandKind, value.kind),
        label .. ' has unsupported kind')
    assert(value.kind ~= CommandKind.WORKFLOW,
        label .. ' cannot nest a workflow')
    assert(type(value.preflight) == 'function',
        label .. ' requires preflight')
    assert(type(value.execute) == 'function',
        label .. ' requires execute')
    assert(value.workflow == nil, label .. ' must omit workflow')
    assert(value.claims == nil or type(value.claims) == 'function',
        label .. ' claims must be callable')
    assert(value.diagnostics == nil or type(value.diagnostics) == 'function',
        label .. ' diagnostics must be callable')
    Internals.retry(value, label)
    Internals.verification(value, label)
    Internals.cleanup(value, label)
    if is_step then
        assert(value.normalize == nil,
            label .. ' uses workflow state and must omit normalize')
        assert(value.default_timeout_ms == nil,
            label .. ' inherits its workflow deadline')
    end
end

---Validates the containing workflow and all named steps.
---@param value table
---@param label string
function Internals.workflow(value, label)
    assert(value.execute == nil, label .. ' workflow must omit execute')
    assert(value.claims == nil and value.operation_key == nil and
        value.verify == nil and value.cleanup == nil,
        label .. ' containing workflow must omit step-owned policies')
    assert(value.execution_retry_policy == RetryPolicy.ONCE,
        label .. ' workflow requires once execution policy')
    assert(value.intrinsic_verification == IntrinsicKind.EXECUTION_RECEIPT,
        label .. ' workflow requires execution_receipt verification')
    assert(type(value.workflow) == 'table',
        label .. ' requires workflow')
    assert(type(value.workflow.steps) == 'table',
        label .. ' workflow steps must be a table')
    local step_count = Internals.array_length(value.workflow.steps,
        label .. ' workflow steps')
    assert(type(value.workflow.result) == 'function',
        label .. ' workflow requires a result projector')
    local names = {}
    for index = 1, step_count do
        local step = value.workflow.steps[index]
        local step_label = ('%s step %d'):format(label, index)
        assert(type(step) == 'table', step_label .. ' must be a table')
        assert(type(step.name) == 'string' and step.name ~= '',
            step_label .. ' requires a nonempty name')
        assert(not names[step.name], label .. ' has duplicate step ' .. step.name)
        names[step.name] = true
        Internals.executable(step, step_label, true)
    end
end

---Validates and freezes one complete command definition.
---@param value table
---@return dwarfspec.CommandDefinition
function Definition.validate(value)
    assert(type(value) == 'table', 'command definition must be a table')
    local label = type(value.name) == 'string' and value.name ~= '' and
        ('command %q'):format(value.name) or 'command definition'
    assert(type(value.name) == 'string' and value.name ~= '',
        'command definition requires a nonempty name')
    assert(type(value.normalize) == 'function', label .. ' requires normalize')
    assert(type(value.preflight) == 'function', label .. ' requires preflight')
    assert(Internals.enum_contains(CommandKind, value.kind),
        label .. ' has unsupported kind')
    Internals.optional_timeout(value.default_timeout_ms,
        label .. ' default_timeout_ms')
    assert(value.diagnostics == nil or type(value.diagnostics) == 'function',
        label .. ' diagnostics must be callable')
    if value.kind == CommandKind.WORKFLOW then
        Internals.workflow(value, label)
    else
        Internals.executable(value, label, false)
    end
    local definition = Internals.freeze(value)
    VALIDATED[definition] = true
    return definition
end

---Returns whether a definition was validated by this module.
---@param definition any
---@return boolean
function Definition.is_validated(definition)
    return VALIDATED[definition] == true
end

return Definition
