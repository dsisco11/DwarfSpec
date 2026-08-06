-- Explicit immutable outcomes shared by command gates and primary execution.

local Diagnostics = require('dwarfspec.driver.command.diagnostics')
local diagnostics = Diagnostics.new()

---@class dwarfspec.CommandOutcomes
local Outcomes = {}
local EFFECT_ABSENT_OUTCOMES = setmetatable({}, {__mode='k'})

---@class dwarfspec.driver.command.OutcomeInternals
local Internals = {}

---Creates a read-only proxy around a detached table.
---@param source table
---@param label string
---@return table
function Internals.read_only(source, label)
    return setmetatable({}, {
        __index=source,
        __newindex=function()
            error(label .. ' is immutable', 2)
        end,
        __pairs=function() return pairs(source) end,
        __len=function() return #source end,
        __metatable=false,
    })
end

---Copies plain bounded diagnostic or receipt data through the shared sanitizer.
---@param value any
---@param label string
---@return any
function Internals.copy_plain(value, label)
    return diagnostics:sanitize(value, label)
end

---Creates one immutable outcome while preserving public result identity.
---@param values table
---@return table
function Internals.outcome(values)
    return Internals.read_only(values, 'command outcome')
end

---Validates optional bounded evidence.
---@param evidence any
---@return table|nil
function Internals.evidence(evidence)
    if evidence == nil then return nil end
    assert(type(evidence) == 'table', 'outcome evidence must be a table')
    return Internals.copy_plain(evidence, 'outcome evidence')
end

---Validates nonempty bounded evidence required as terminal proof.
---@param evidence any
---@param label string
---@return table
function Internals.required_evidence(evidence, label)
    assert(type(evidence) == 'table' and next(evidence) ~= nil,
        label .. ' requires nonempty observation evidence')
    return Internals.copy_plain(evidence, label .. ' evidence')
end

---Validates and copies an optional private receipt.
---@param receipt any
---@param label string
---@return any
function Internals.receipt(receipt, label)
    if receipt == nil then return nil end
    return Internals.copy_plain(receipt, label)
end

---Creates a successful gate or intrinsic-verification observation.
---@param value any
---@param evidence? table
---@return dwarfspec.GateResult
function Outcomes.ready(value, evidence)
    return Internals.outcome({
        kind='ready', value=value, evidence=Internals.evidence(evidence),
    })
end

---Creates a retryable not-ready observation.
---@param reason string
---@param evidence? table
---@return dwarfspec.GateResult
function Outcomes.pending(reason, evidence)
    assert(type(reason) == 'string' and reason ~= '',
        'pending outcome requires a nonempty reason')
    return Internals.outcome({
        kind='pending', message=reason, evidence=Internals.evidence(evidence),
    })
end

---Creates a fatal observation that must not be retried.
---@param message string
---@param evidence? table
---@return dwarfspec.GateResult
function Outcomes.fatal(message, evidence)
    assert(type(message) == 'string' and message ~= '',
        'fatal outcome requires a nonempty message')
    return Internals.outcome({
        kind='fatal', message=message, evidence=Internals.evidence(evidence),
    })
end

---Creates intrinsic-only proof that a registered effect no longer exists.
---@param message string
---@param evidence table Nonempty bounded evidence identifying the observation.
---@return dwarfspec.IntrinsicVerificationResult
function Outcomes.effect_absent(message, evidence)
    assert(type(message) == 'string' and message ~= '',
        'effect_absent outcome requires a nonempty message')
    local outcome = Internals.outcome({
        kind='effect_absent', message=message,
        evidence=Internals.required_evidence(evidence, 'effect_absent outcome'),
    })
    EFFECT_ABSENT_OUTCOMES[outcome] = true
    return outcome
end

---Returns whether a value was created by effect_absent.
---@param outcome any
---@return boolean
function Outcomes.is_effect_absent(outcome)
    return EFFECT_ABSENT_OUTCOMES[outcome] == true
end

---Creates a successful primary-execution result.
---@param public_result any
---@param receipt? any
---@param effect_receipt? any
---@return dwarfspec.ExecutionResult
function Outcomes.executed(public_result, receipt, effect_receipt)
    return Internals.outcome({
        kind='executed', public_result=public_result,
        receipt=Internals.receipt(receipt, 'verification receipt'),
        effect_receipt=Internals.receipt(effect_receipt, 'effect receipt'),
    })
end

---Creates an explicit retry-safe primary-execution result.
---@param reason string
---@param attempt_receipt? any
---@param effect_receipt? any
---@param evidence? table
---@return dwarfspec.ExecutionResult
function Outcomes.retry(reason, attempt_receipt, effect_receipt, evidence)
    assert(type(reason) == 'string' and reason ~= '',
        'retry outcome requires a nonempty reason')
    return Internals.outcome({
        kind='retry', reason=reason,
        attempt_receipt=Internals.receipt(attempt_receipt, 'attempt receipt'),
        effect_receipt=Internals.receipt(effect_receipt, 'effect receipt'),
        evidence=Internals.evidence(evidence),
    })
end

---Creates a structured terminal primary-execution failure.
---@param message string
---@param effect_receipt? any
---@param evidence? table
---@return dwarfspec.ExecutionResult
function Outcomes.failed(message, effect_receipt, evidence)
    assert(type(message) == 'string' and message ~= '',
        'failed outcome requires a nonempty message')
    return Internals.outcome({
        kind='failed', message=message,
        effect_receipt=Internals.receipt(effect_receipt, 'effect receipt'),
        evidence=Internals.evidence(evidence),
    })
end

return Outcomes
