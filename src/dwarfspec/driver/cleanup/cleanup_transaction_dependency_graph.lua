-- Projects cleanup transaction dependencies onto the generic directed acyclic graph.

local DirectedAcyclicGraph = require('dwarfspec.graphs.directed_acyclic_graph')

---@class dwarfspec.CleanupTransactionDependencyGraph
---@field private _graph dwarfspec.DirectedAcyclicGraph
local CleanupTransactionDependencyGraph = {}
CleanupTransactionDependencyGraph.__index = CleanupTransactionDependencyGraph

---Creates one temporary transaction-level dependency graph.
---@return dwarfspec.CleanupTransactionDependencyGraph
function CleanupTransactionDependencyGraph.new()
    return setmetatable({_graph=DirectedAcyclicGraph.new()},
        CleanupTransactionDependencyGraph)
end

---Adds one transaction node.
---@param transaction_id string
---@return boolean
function CleanupTransactionDependencyGraph:add_transaction(transaction_id)
    return self._graph:add_node(transaction_id)
end

---Projects a prerequisite-to-dependent transaction relationship.
---@param prerequisite_id string
---@param dependent_id string
---@return boolean
function CleanupTransactionDependencyGraph:add_dependency(prerequisite_id,
        dependent_id)
    return self._graph:add_edge(prerequisite_id, dependent_id)
end

---Returns dependent-before-prerequisite execution IDs using caller tie-breaking.
---@param less fun(left: string, right: string): boolean
---@return string[]
function CleanupTransactionDependencyGraph:cleanup_order(less)
    local ordered = self._graph:topological_order(nil, less)
    local reversed = {}
    for index = #ordered, 1, -1 do reversed[#reversed + 1] = ordered[index] end
    return reversed
end

return CleanupTransactionDependencyGraph
