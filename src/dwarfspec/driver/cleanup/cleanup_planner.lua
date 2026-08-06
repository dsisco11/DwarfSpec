-- Plans dependency-safe cleanup transaction execution order.

local CleanupTransactionDependencyGraph = require(
    'dwarfspec.driver.cleanup.cleanup_transaction_dependency_graph')

---@class dwarfspec.CleanupPlanner
---@field private _dependent_ids fun(transaction_id: string): string[]
local CleanupPlanner = {}
CleanupPlanner.__index = CleanupPlanner

---@class dwarfspec.driver.cleanup.CleanupPlannerInternals
local Internals = {}

---Validates one contiguous transaction array.
---@param transactions any
---@return table[]
function Internals.transactions(transactions)
    assert(type(transactions) == 'table', 'cleanup transactions must be an array')
    local count = 0
    for index in pairs(transactions) do
        assert(type(index) == 'number' and index >= 1 and index % 1 == 0,
            'cleanup transactions must have positive integer indexes')
        count = count + 1
    end
    assert(count == #transactions, 'cleanup transactions must be contiguous')
    return transactions
end

---Creates a transaction dependency graph for one pending subset.
---@param planner dwarfspec.CleanupPlanner
---@param transactions table[]
---@return dwarfspec.CleanupTransactionDependencyGraph
function Internals.graph(planner, transactions)
    local graph = CleanupTransactionDependencyGraph.new()
    local selected = {}
    for _, transaction in ipairs(transactions) do
        local transaction_id = transaction:transaction_id()
        assert(not selected[transaction_id], 'duplicate cleanup transaction ID')
        selected[transaction_id] = transaction
        graph:add_transaction(transaction_id)
    end
    for transaction_id in pairs(selected) do
        for _, dependent_id in ipairs(planner._dependent_ids(transaction_id)) do
            if selected[dependent_id] then
                graph:add_dependency(transaction_id, dependent_id)
            end
        end
    end
    return graph
end

---Creates a planner with a read-only active-dependency lookup capability.
---@param dependent_ids fun(transaction_id: string): string[]
---@return dwarfspec.CleanupPlanner
function CleanupPlanner.new(dependent_ids)
    assert(type(dependent_ids) == 'function',
        'cleanup planner requires dependent transaction lookup')
    return setmetatable({_dependent_ids=dependent_ids}, CleanupPlanner)
end

---Returns whether active dependents block manual cleanup of one transaction.
---@param transaction_id string
---@param active_transaction_ids table<string, true>
---@return string[]
function CleanupPlanner:blocking_dependents(transaction_id, active_transaction_ids)
    assert(type(transaction_id) == 'string' and transaction_id ~= '',
        'cleanup transaction ID must be a nonempty string')
    assert(type(active_transaction_ids) == 'table',
        'active cleanup transaction IDs are required')
    local blocked = {}
    for _, dependent_id in ipairs(self._dependent_ids(transaction_id)) do
        if active_transaction_ids[dependent_id] then blocked[#blocked + 1] = dependent_id end
    end
    table.sort(blocked)
    return blocked
end

---Simulates a prospective transaction against active transaction dependencies.
---@param transaction_ids string[]
---@param prospective_id string
---@param prerequisite_ids string[]
function CleanupPlanner:validate_prospective(transaction_ids, prospective_id,
        prerequisite_ids)
    assert(type(prospective_id) == 'string' and prospective_id ~= '',
        'prospective cleanup transaction ID must be a nonempty string')
    assert(type(prerequisite_ids) == 'table',
        'prospective cleanup prerequisites must be an array')
    local graph = CleanupTransactionDependencyGraph.new()
    local active = {}
    for _, transaction_id in ipairs(transaction_ids) do
        assert(type(transaction_id) == 'string' and transaction_id ~= '',
            'active cleanup transaction ID must be a nonempty string')
        assert(not active[transaction_id], 'duplicate active cleanup transaction ID')
        active[transaction_id] = true
        graph:add_transaction(transaction_id)
    end
    assert(not active[prospective_id],
        'prospective cleanup transaction ID is already active')
    graph:add_transaction(prospective_id)
    for transaction_id in pairs(active) do
        for _, dependent_id in ipairs(self._dependent_ids(transaction_id)) do
            if active[dependent_id] then
                graph:add_dependency(transaction_id, dependent_id)
            end
        end
    end
    for _, prerequisite_id in ipairs(prerequisite_ids) do
        assert(active[prerequisite_id],
            'prospective cleanup prerequisite is not active')
        graph:add_dependency(prerequisite_id, prospective_id)
    end
end

---Returns dependent-before-prerequisite cleanup order with LIFO tie-breaking.
---@param transactions table[]
---@return table[]
function CleanupPlanner:order(transactions)
    transactions = Internals.transactions(transactions)
    local by_id = {}
    for _, transaction in ipairs(transactions) do
        by_id[transaction:transaction_id()] = transaction
    end
    local graph = Internals.graph(self, transactions)
    local ordered_ids = graph:cleanup_order(function(left, right)
        return by_id[left]:registration_ordinal() <
            by_id[right]:registration_ordinal()
    end)
    local ordered = {}
    for _, transaction_id in ipairs(ordered_ids) do
        ordered[#ordered + 1] = by_id[transaction_id]
    end
    return ordered
end

return CleanupPlanner
