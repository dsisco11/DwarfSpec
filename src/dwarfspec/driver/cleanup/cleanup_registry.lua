-- Owns pending cleanup transactions and executes them through one planner.

local CleanupPlanner = require('dwarfspec.driver.cleanup.cleanup_planner')
local CleanupTransaction = require(
    'dwarfspec.driver.cleanup.cleanup_transaction')
local CleanupState = require('dwarfspec.protocol.enums.cleanup_states')

---@class dwarfspec.CleanupRegistry
---@field private _transactions table<string, dwarfspec.CleanupTransaction>
---@field private _planner dwarfspec.CleanupPlanner
local CleanupRegistry = {}
CleanupRegistry.__index = CleanupRegistry

---@class dwarfspec.driver.cleanup.CleanupRegistryInternals
local Internals = {}

---Creates one owner-local pending cleanup registry.
---@param dependent_ids fun(transaction_id: string): string[]
---@return dwarfspec.CleanupRegistry
function CleanupRegistry.new(dependent_ids)
    return setmetatable({_transactions={}, _pending={},
        _planner=CleanupPlanner.new(dependent_ids)}, CleanupRegistry)
end

---Adds one newly registered pending transaction.
---@param transaction dwarfspec.CleanupTransaction
function CleanupRegistry:add(transaction)
    assert(type(transaction) == 'table' and type(transaction.transaction_id) == 'function',
        'cleanup registry requires a cleanup transaction')
    local transaction_id = transaction:transaction_id()
    assert(self._transactions[transaction_id] == nil,
        'cleanup transaction is already registered')
    self._transactions[transaction_id] = transaction
    self._pending[transaction_id] = true
end

---Removes one transaction from automatic pending work before execution.
---@param transaction dwarfspec.CleanupTransaction
function CleanupRegistry:remove_pending(transaction)
    local transaction_id = transaction:transaction_id()
    assert(self._transactions[transaction_id] == transaction,
        'cleanup transaction is not registered in this cleanup registry')
    self._pending[transaction_id] = nil
    -- The execution index retains the handle and terminal evidence after active
    -- pending work is removed.
end

---Returns active pending transaction IDs as a set.
---@return table<string, true>
function CleanupRegistry:pending_ids()
    local pending = {}
    for transaction_id in pairs(self._pending) do
        pending[transaction_id] = true
    end
    return pending
end

---Returns the pending transactions as a detached deterministic array.
---@return dwarfspec.CleanupTransaction[]
function CleanupRegistry:pending_transactions()
    local transactions = {}
    for transaction_id in pairs(self._pending) do
        transactions[#transactions + 1] = self._transactions[transaction_id]
    end
    table.sort(transactions, function(left, right)
        return left:registration_ordinal() < right:registration_ordinal()
    end)
    return transactions
end

---Returns transactions whose retained claims still protect prerequisites.
---@return table<string, true>
function CleanupRegistry:protection_ids()
    local protected = {}
    for transaction_id, transaction in pairs(self._transactions) do
        local state = transaction:state()
        if state == CleanupState.PENDING or state == CleanupState.RUNNING or
                state == CleanupState.FAILED or state == CleanupState.UNCONFIRMED then
            protected[transaction_id] = true
        end
    end
    return protected
end

---Returns active dependents that block manual execution of one transaction.
---@param transaction_id string
---@return string[]
function CleanupRegistry:blocking_dependents(transaction_id)
    return self._planner:blocking_dependents(transaction_id, self:protection_ids())
end

---Executes all pending transactions in dependency-safe deterministic order.
---@param reason string
---@return boolean, table[]
function CleanupRegistry:execute_all(reason)
    assert(type(reason) == 'string' and reason ~= '',
        'cleanup execution reason must be a nonempty string')
    local transactions = {}
    for transaction_id in pairs(self._pending) do
        transactions[#transactions + 1] = self._transactions[transaction_id]
    end
    local failures = {}
    for _, transaction in ipairs(self._planner:order(transactions)) do
        local blocked = self:blocking_dependents(transaction:transaction_id())
        if #blocked > 0 then
            CleanupTransaction._dependency_blocked(transaction, blocked)
            failures[#failures + 1] = 'cleanup transaction failed: dependency_blocked: ' ..
                table.concat(blocked, ',')
        else
            local succeeded, failure = xpcall(function() transaction:execute(reason) end,
                debug.traceback)
            if not succeeded then failures[#failures + 1] = failure end
        end
    end
    return #failures == 0, failures
end

return CleanupRegistry
