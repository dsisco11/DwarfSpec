-- Public stage-guarded view of one engine-owned cleanup transaction.

---@class dwarfspec.CleanupTransactionHandle
---@field private _transaction dwarfspec.CleanupTransaction
---@field private _owner dwarfspec.ExecutionOwnerIdentity
---@field private _current_owner fun(): dwarfspec.ExecutionOwnerIdentity
---@field private _assert_stage fun(owner: dwarfspec.ExecutionOwnerIdentity)
local CleanupTransactionHandle = {}
CleanupTransactionHandle.__index = CleanupTransactionHandle

---@class dwarfspec.driver.cleanup.CleanupTransactionHandleInternals
local Internals = {}

---Returns whether the active lifecycle owner is nested within the transaction owner.
---@param owner table
---@param active table
---@return boolean
function Internals.contains(owner, active)
    if owner.service_run_id ~= active.service_run_id then return false end
    if owner.owner_scope == 'service_run' then return true end
    if owner.suite_execution_id ~= active.suite_execution_id then return false end
    if owner.owner_scope == 'suite_execution' then return true end
    return owner.test_attempt_id == active.test_attempt_id
end

---Creates a caller-visible handle without exposing mutable transaction internals.
---@param transaction dwarfspec.CleanupTransaction
---@param owner dwarfspec.ExecutionOwnerIdentity
---@param current_owner fun(): dwarfspec.ExecutionOwnerIdentity
---@param assert_stage fun(owner: dwarfspec.ExecutionOwnerIdentity)
---@return dwarfspec.CleanupTransaction
function CleanupTransactionHandle.new(transaction, owner, current_owner,
        assert_stage)
    assert(type(transaction) == 'table' and
        type(transaction.execute) == 'function',
        'cleanup handle requires a transaction')
    assert(type(owner) == 'table', 'cleanup handle requires an owner')
    assert(type(current_owner) == 'function',
        'cleanup handle requires a lifecycle owner callback')
    assert(type(assert_stage) == 'function',
        'cleanup handle requires a stage guard callback')
    return setmetatable({_transaction=transaction, _owner=owner,
        _current_owner=current_owner, _assert_stage=assert_stage},
        CleanupTransactionHandle)
end

---Manually executes pending cleanup within its owning lifecycle.
---@param reason? string
---@return boolean
function CleanupTransactionHandle:execute(reason)
    local active = self._current_owner()
    assert(Internals.contains(self._owner, active),
        'cleanup handle execution is forbidden outside its owning lifecycle')
    self._assert_stage(self._owner)
    return self._transaction:execute(reason)
end

---Returns whether this transaction remains registered for teardown.
---@return boolean
function CleanupTransactionHandle:isPending()
    return self._transaction:isPending()
end

---Returns immutable active claim references owned by this transaction.
---@return dwarfspec.ResourceClaimReference[]
function CleanupTransactionHandle:claimReferences()
    return self._transaction:claimReferences()
end

return CleanupTransactionHandle
