-- Folds authoritative cleanup lifecycle events into detached owner ledgers.

local CleanupDisposition = require(
    'dwarfspec.protocol.enums.cleanup_terminal_dispositions')
local EventType = require('dwarfspec.protocol.enums.event_types')

---@class dwarfspec.host.execution.CleanupResultMaterializer
local M = {}

local EVENT_TYPES = {
    [EventType.CLEANUP_TRANSACTION_REGISTERED]=true,
    [EventType.CLEANUP_TRANSACTION_STARTED]=true,
    [EventType.CLEANUP_TRANSACTION_FINISHED]=true,
    [EventType.CLEANUP_TRANSACTION_ABANDONED]=true,
}

---Returns a detached plain copy of one event-owned value.
---@param value table
---@return table
local function copy(value)
    return require('dwarfspec.protocol.events').copy_json(value,
        'cleanup result projection')
end

---Returns whether a lifecycle event belongs to the requested owner.
---@param event table
---@param owner dwarfspec.ExecutionOwnerIdentity
---@return boolean
local function belongs_to(event, owner)
    return event.owner_scope == owner.owner_scope and
        event.service_run_id == owner.service_run_id and
        event.suite_execution_id == owner.suite_execution_id and
        event.test_attempt_id == owner.test_attempt_id
end

---Copies a registration event into its eventual terminal result record.
---@param event dwarfspec.CleanupLifecycleEvent
---@return dwarfspec.CleanupTransactionResult
local function registered_result(event)
    return {
        transaction_id=event.transaction_id,
        registration_ordinal=event.registration_ordinal,
        label=event.label,
        lifetime=event.lifetime,
        owner_scope=event.owner_scope,
        service_run_id=event.service_run_id,
        suite_execution_id=event.suite_execution_id,
        test_attempt_id=event.test_attempt_id,
        command_invocation_id=event.command_invocation_id,
        registered_at_ms=event.registered_at_ms,
    }
end

---Folds an owner's cleanup lifecycle events into registration-ordered results.
---@param events table[]
---@param owner dwarfspec.ExecutionOwnerIdentity
---@return dwarfspec.CleanupTransactionResult[]
function M.fold_owner(events, owner)
    assert(type(events) == 'table', 'cleanup materialization requires events')
    assert(type(owner) == 'table', 'cleanup materialization requires owner')
    local results = {}
    for _, envelope in ipairs(events) do
        if EVENT_TYPES[envelope.type] then
            local event = envelope.payload.cleanup_event
            if belongs_to(event, owner) then
                local result = results[event.transaction_id]
                if envelope.type == EventType.CLEANUP_TRANSACTION_REGISTERED then
                    assert(result == nil,
                        'cleanup journal registered a transaction more than once')
                    results[event.transaction_id] = registered_result(event)
                else
                    assert(result ~= nil,
                        'cleanup journal changed an unregistered transaction')
                    if envelope.type == EventType.CLEANUP_TRANSACTION_STARTED then
                        result.execution_started_at_ms = event.execution_started_at_ms
                    else
                        assert(result.disposition == nil,
                            'cleanup journal terminalized a transaction more than once')
                        result.disposition = event.disposition
                        result.completed_at_ms = event.completed_at_ms
                        if event.disposition == CleanupDisposition.ABANDONED then
                            result.evidence = copy(event.evidence)
                        else
                            result.restore_outcome = event.restore_outcome
                            result.verification_outcome = event.verification_outcome
                            result.evidence = copy(event.evidence)
                        end
                    end
                end
            end
        end
    end
    local ordered = {}
    for _, result in pairs(results) do
        assert(result.disposition ~= nil,
            'cleanup journal has a registration without a terminal disposition')
        ordered[#ordered + 1] = result
    end
    table.sort(ordered, function(left, right)
        return left.registration_ordinal < right.registration_ordinal
    end)
    return copy(ordered)
end

return M
