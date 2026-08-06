-- Executes one receipt-backed cleanup transaction exactly once.

local Deadline = require('dwarfspec.driver.command.deadline')
local Diagnostics = require('dwarfspec.driver.command.diagnostics')
local CleanupState = require('dwarfspec.protocol.enums.cleanup_states')
local CommandKind = require('dwarfspec.protocol.enums.command_kinds')

---@class dwarfspec.CleanupTransaction
---@field private _transaction_id string
---@field private _registration_ordinal integer
---@field private _state dwarfspec.ECleanupState
---@field private _receipt table
---@field private _restore fun(context: dwarfspec.CleanupExecutionContext, receipt: table)
---@field private _verify fun(context: dwarfspec.CleanupExecutionContext, receipt: table): boolean|table|nil
---@field private _dependencies table
local CleanupTransaction = {}
CleanupTransaction.__index = CleanupTransaction

---@class dwarfspec.driver.cleanup.CleanupTransactionInternals
local Internals = {}
Internals.diagnostics = Diagnostics.new({max_depth=8, max_entries=64,
    max_string_length=512, max_records=64, pending_sample_limit=3})

---Validates a bounded nonempty identifier.
---@param value any
---@param label string
---@return string
function Internals.identifier(value, label)
    assert(type(value) == 'string' and value ~= '' and #value <= 128,
        label .. ' must be a bounded nonempty string')
    return value
end

---Converts one callback failure to bounded cleanup evidence text.
---@param value any
---@return string
function Internals.bounded_error(value)
    local succeeded, text = pcall(tostring, value)
    if not succeeded then text = '<unprintable cleanup error>' end
    if #text <= 480 then return text end
    return text:sub(1, 477) .. '...'
end

---Rejects metatable-bearing tables before receipt traversal can invoke behavior.
---@param value any
---@param label string
---@param active? table<table, true>
function Internals.assert_plain_receipt(value, label, active)
    if type(value) ~= 'table' then return end
    assert(debug.getmetatable(value) == nil,
        label .. ' cannot contain metatables')
    active = active or {}
    assert(not active[value], label .. ' cannot contain cycles')
    active[value] = true
    for key, entry in next, value do
        assert(type(key) == 'string' or (type(key) == 'number' and key >= 1 and
            key % 1 == 0), label .. ' keys must be strings or positive integers')
        Internals.assert_plain_receipt(entry, label, active)
    end
    active[value] = nil
end

---Creates an immutable cleanup callback context.
---@param transaction dwarfspec.CleanupTransaction
---@param mode string
---@param deadline dwarfspec.CommandDeadline
---@return dwarfspec.CleanupExecutionContext
function Internals.context(transaction, mode, deadline, cancellation)
    local dependencies = transaction._dependencies
    local context = {}
    ---Returns remaining cleanup execution time.
    ---@return integer
    function context:remaining_ms() return deadline:remaining_ms() end
    ---Returns cleanup cancellation state.
    ---@return boolean, string|nil
    function context:cancellation()
        return cancellation()
    end
    ---Records bounded cleanup evidence.
    ---@param kind string
    ---@param evidence table
    function context:record_diagnostic(kind, evidence)
        return dependencies.record_diagnostic(kind,
            Internals.diagnostics:sanitize(evidence, 'cleanup diagnostic'))
    end
    ---Invokes a nested read-only command during cleanup verification.
    ---@param kind string
    ---@param name string
    ---@param ... any
    ---@return any
    function context:invoke_readonly(kind, name, ...)
        assert(mode == 'verification',
            'cleanup restore cannot invoke public commands')
        assert(kind == CommandKind.QUERY or kind == CommandKind.ASSERTION,
            'cleanup verification can invoke only read-only commands')
        return dependencies.invoke_readonly(kind, name, ...)
    end
    return setmetatable({}, {__index=context, __newindex=function()
        error('cleanup execution context is immutable', 2)
    end, __metatable=false})
end

---Returns a deterministic composed cleanup failure message.
---@param parts string[]
---@return string
function Internals.failure(parts)
    return 'cleanup transaction failed: ' .. table.concat(parts, '; ')
end

---Creates one receipt-backed cleanup transaction.
---@param options table
---@return dwarfspec.CleanupTransaction
function CleanupTransaction.new(options)
    assert(type(options) == 'table', 'cleanup transaction options are required')
    assert(type(options.registration_ordinal) == 'number' and
        options.registration_ordinal >= 1 and options.registration_ordinal % 1 == 0,
        'cleanup registration ordinal must be a positive integer')
    assert(type(options.restore) == 'function', 'cleanup restore must be callable')
    assert(type(options.verify) == 'function', 'cleanup verification must be callable')
    assert(type(options.now_ms) == 'function', 'cleanup transaction requires clock')
    assert(type(options.remove_pending) == 'function',
        'cleanup transaction requires pending removal')
    assert(type(options.release_verified) == 'function',
        'cleanup transaction requires verified claim release')
    Internals.assert_plain_receipt(options.receipt, 'cleanup receipt')
    local receipt = Internals.diagnostics:sanitize(options.receipt,
        'cleanup receipt')
    assert(type(receipt) == 'table', 'cleanup receipt must be bounded plain data')
    local dependencies = {
        now_ms=options.now_ms,
        timeout_ms=options.cleanup_timeout_ms or 10000,
        remove_pending=options.remove_pending,
        release_verified=options.release_verified,
        retain_unresolved=options.retain_unresolved or function() end,
        new_cancellation=options.new_cancellation or function()
            return function() return false, nil end
        end,
        wait=options.wait or function() end,
        invoke_readonly=options.invoke_readonly or function()
            error('nested cleanup verification commands are unavailable', 2)
        end,
        record_diagnostic=options.record_diagnostic or function() end,
        claim_references=options.claim_references or function() return {} end,
        assert_executable=options.assert_executable or function() end,
        blocking_dependents=options.blocking_dependents or function() return {} end,
        on_started=options.on_started or function() end,
        on_finished=options.on_finished or function() end,
        on_abandoned=options.on_abandoned or function() end,
    }
    Deadline.new(dependencies.now_ms, dependencies.timeout_ms)
    return setmetatable({_transaction_id=Internals.identifier(options.transaction_id,
        'cleanup transaction ID'), _registration_ordinal=options.registration_ordinal,
        _label=Internals.identifier(options.label, 'cleanup label'),
        _receipt=receipt, _restore=options.restore, _verify=options.verify,
        _state=CleanupState.PENDING, _dependencies=dependencies, _evidence={}},
        CleanupTransaction)
end

---Returns the stable transaction identifier for planner use.
---@return string
function CleanupTransaction:transaction_id() return self._transaction_id end

---Returns the owning registry's deterministic registration ordinal.
---@return integer
function CleanupTransaction:registration_ordinal() return self._registration_ordinal end

---Returns whether automatic or manual cleanup remains eligible.
---@return boolean
function CleanupTransaction:isPending() return self._state == CleanupState.PENDING end

---Returns frozen references for this transaction's active resource claims.
---@return dwarfspec.ResourceClaimReference[]
function CleanupTransaction:claimReferences()
    return Internals.diagnostics:sanitize(self._dependencies.claim_references(),
        'cleanup claim references')
end

---Returns the terminal or active cleanup state for internal result projection.
---@return dwarfspec.ECleanupState
function CleanupTransaction:state() return self._state end

---Returns immutable cleanup evidence for result projection.
---@return table
function CleanupTransaction:evidence()
    return Internals.diagnostics:sanitize(self._evidence, 'cleanup evidence')
end

---Records an interruption that prevented a conclusive cleanup outcome.
---@param transaction dwarfspec.CleanupTransaction
---@param evidence table
function CleanupTransaction._mark_unconfirmed(transaction, evidence)
    assert(getmetatable(transaction) == CleanupTransaction,
        'unconfirmed cleanup requires a cleanup transaction')
    assert(transaction._state == CleanupState.PENDING or
        transaction._state == CleanupState.RUNNING,
        'only active cleanup can become unconfirmed')
    transaction._dependencies.remove_pending(transaction)
    transaction._state = CleanupState.UNCONFIRMED
    transaction._evidence = Internals.diagnostics:sanitize(evidence,
        'unconfirmed cleanup evidence')
    transaction._dependencies.retain_unresolved(transaction._transaction_id)
    transaction._dependencies.on_finished(transaction, transaction._state,
        transaction._evidence)
end

---Records a terminal prerequisite block without invoking cleanup callbacks.
---@param transaction dwarfspec.CleanupTransaction
---@param dependent_ids string[]
function CleanupTransaction._dependency_blocked(transaction, dependent_ids)
    assert(getmetatable(transaction) == CleanupTransaction,
        'dependency-blocked cleanup requires a cleanup transaction')
    assert(transaction._state == CleanupState.PENDING,
        'only pending cleanup can become dependency-blocked')
    assert(type(dependent_ids) == 'table' and #dependent_ids > 0,
        'dependency-blocked cleanup requires active dependents')
    transaction._dependencies.remove_pending(transaction)
    transaction._state = CleanupState.FAILED
    transaction._evidence = Internals.diagnostics:sanitize({
        reason='dependency_blocked', dependent_transaction_ids=dependent_ids,
    }, 'dependency-blocked cleanup evidence')
    transaction._dependencies.retain_unresolved(transaction._transaction_id)
    transaction._dependencies.on_finished(transaction, transaction._state,
        transaction._evidence)
end

---Records the runner-only proof that an effect self-rolled back before publication.
---@param transaction dwarfspec.CleanupTransaction
---@param proof table
function CleanupTransaction._abandon_verified(transaction, proof)
    assert(getmetatable(transaction) == CleanupTransaction,
        'abandoned cleanup requires a cleanup transaction')
    assert(transaction._state == CleanupState.PENDING,
        'only pending cleanup can be abandoned')
    assert(type(proof) == 'table',
        'abandoned cleanup requires nonempty absence proof')
    local iterator, state, key = pairs(proof)
    assert(iterator(state, key) ~= nil,
        'abandoned cleanup requires nonempty absence proof')
    proof = Internals.diagnostics:sanitize(proof, 'cleanup absence proof')
    transaction._dependencies.remove_pending(transaction)
    transaction._dependencies.release_verified(transaction._transaction_id, proof)
    transaction._state = CleanupState.ABANDONED
    transaction._evidence = proof
    transaction._dependencies.on_abandoned(transaction, proof)
end

---Executes restore once and polls required verification under a fresh deadline.
---@param reason? string
---@return boolean
function CleanupTransaction:execute(reason)
    self._dependencies.assert_executable()
    if not self:isPending() then return false end
    local blocked = self._dependencies.blocking_dependents(self._transaction_id)
    if #blocked > 0 then
        error(Internals.failure({'dependency_blocked: ' ..
            table.concat(blocked, ',')}), 2)
    end
    self._dependencies.remove_pending(self)
    self._state = CleanupState.RUNNING
    self._dependencies.on_started(self, reason)
    local deadline = Deadline.new(self._dependencies.now_ms,
        self._dependencies.timeout_ms)
    local cancellation = self._dependencies.new_cancellation()
    assert(type(cancellation) == 'function',
        'cleanup cancellation scope must expose a callback')
    local restore_context = Internals.context(self, 'restore', deadline,
        cancellation)
    local restored, restore_error = xpcall(function()
        self._restore(restore_context, self._receipt)
    end, debug.traceback)
    local failures = {}
    if not restored then
        failures[#failures + 1] = 'restore: ' .. Internals.bounded_error(restore_error)
    end
    local verified = false
    local latest_verification_error = nil
    local retained_verification_error = false
    local verification_context = Internals.context(self, 'verification', deadline,
        cancellation)
    while deadline:remaining_ms() > 0 do
        local cancelled, cancellation_reason = cancellation()
        if cancelled then
            failures[#failures + 1] = 'cancelled: ' .. tostring(cancellation_reason)
            break
        end
        local succeeded, observation = xpcall(function()
            return self._verify(verification_context, self._receipt)
        end, debug.traceback)
        if succeeded and observation ~= false and
                (type(observation) ~= 'table' or observation.kind ~= 'pending') then
            if type(observation) == 'table' and observation.kind == 'fatal' then
                failures[#failures + 1] = 'verification: ' .. tostring(observation.message)
                break
            end
            verified = true
            break
        end
        if succeeded and type(observation) == 'table' and observation.kind == 'fatal' then
            failures[#failures + 1] = 'verification: ' .. tostring(observation.message)
            break
        end
        if not succeeded then
            latest_verification_error = Internals.bounded_error(observation)
        end
        local before_wait_ms = deadline:remaining_ms()
        self._dependencies.wait(before_wait_ms)
        if deadline:remaining_ms() >= before_wait_ms then
            if latest_verification_error then
                failures[#failures + 1] = 'verification: ' ..
                    latest_verification_error
                retained_verification_error = true
            end
            failures[#failures + 1] =
                'verification: cleanup scheduler did not advance time'
            break
        end
    end
    if not verified then
        if latest_verification_error and not retained_verification_error then
            failures[#failures + 1] = 'verification: ' ..
                latest_verification_error
        end
        failures[#failures + 1] = 'verification: not confirmed'
    end
    self._evidence = {reason=reason, restore_succeeded=restored,
        verification_succeeded=verified, failures=failures}
    if restored and verified then
        local released, release_error = xpcall(function()
            self._dependencies.release_verified(self._transaction_id, self._evidence)
        end, debug.traceback)
        if released then
            self._state = CleanupState.COMPLETE
            self._dependencies.on_finished(self, self._state, self._evidence)
            return true
        end
        failures[#failures + 1] = 'claim release: ' ..
            Internals.bounded_error(release_error)
    end
    self._state = CleanupState.FAILED
    self._dependencies.retain_unresolved(self._transaction_id)
    self._dependencies.on_finished(self, self._state, self._evidence)
    error(Internals.failure(failures), 2)
end

return CleanupTransaction
