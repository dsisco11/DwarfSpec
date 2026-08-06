---Stores stable string node IDs in a deterministic directed acyclic graph.
---@class dwarfspec.DirectedAcyclicGraph
---@field private _nodes table<string, true>
---@field private _incoming table<string, table<string, true>>
---@field private _outgoing table<string, table<string, true>>
local DirectedAcyclicGraph = {}
DirectedAcyclicGraph.__index = DirectedAcyclicGraph

---Provides module-private operations for DirectedAcyclicGraph instances.
---@class dwarfspec.graphs.DirectedAcyclicGraphInternals
local Internals = {}

---Creates an empty directed acyclic graph.
---@return dwarfspec.DirectedAcyclicGraph
function DirectedAcyclicGraph.new()
    return setmetatable({
        _nodes={},
        _incoming={},
        _outgoing={},
    }, DirectedAcyclicGraph)
end

---Validates one public node-ID argument.
---@param node_id any
---@param argument_name string
---@param error_level integer
function Internals.validate_node_id(node_id, argument_name, error_level)
    if type(node_id) ~= 'string' or node_id == '' then
        error(('%s must be a nonempty string'):format(argument_name), error_level)
    end
end

---Validates and returns one known node ID.
---@param graph dwarfspec.DirectedAcyclicGraph
---@param node_id any
---@param argument_name string
---@param error_level integer
---@return string
function Internals.require_node(graph, node_id, argument_name, error_level)
    Internals.validate_node_id(node_id, argument_name, error_level)
    if not graph._nodes[node_id] then
        error(('unknown node ID for %s: %q'):format(argument_name, node_id),
            error_level)
    end
    return node_id
end

---Returns whether target_id is reachable from start_id.
---@param graph dwarfspec.DirectedAcyclicGraph
---@param start_id string
---@param target_id string
---@return boolean
function Internals.reaches(graph, start_id, target_id)
    local pending = {start_id}
    local visited = {}
    while #pending > 0 do
        local node_id = table.remove(pending)
        if node_id == target_id then return true end
        if not visited[node_id] then
            visited[node_id] = true
            for successor_id in pairs(graph._outgoing[node_id]) do
                if not visited[successor_id] then
                    table.insert(pending, successor_id)
                end
            end
        end
    end
    return false
end

---Compares two ready node IDs using caller policy and lexical fallback.
---@param left string
---@param right string
---@param less? fun(left: string, right: string): boolean
---@return boolean
function Internals.comes_before(left, right, less)
    if less then
        local left_before = not not less(left, right)
        local right_before = not not less(right, left)
        if left_before ~= right_before then return left_before end
    end
    return left < right
end

---Adds a node and returns whether it was newly inserted.
---@param node_id string
---@return boolean inserted
function DirectedAcyclicGraph:add_node(node_id)
    Internals.validate_node_id(node_id, 'node_id', 2)
    if self._nodes[node_id] then return false end
    self._nodes[node_id] = true
    self._incoming[node_id] = {}
    self._outgoing[node_id] = {}
    return true
end

---Removes a node and all incident edges.
---@param node_id string
---@return boolean removed
function DirectedAcyclicGraph:remove_node(node_id)
    Internals.validate_node_id(node_id, 'node_id', 2)
    if not self._nodes[node_id] then return false end

    for predecessor_id in pairs(self._incoming[node_id]) do
        self._outgoing[predecessor_id][node_id] = nil
    end
    for successor_id in pairs(self._outgoing[node_id]) do
        self._incoming[successor_id][node_id] = nil
    end
    self._incoming[node_id] = nil
    self._outgoing[node_id] = nil
    self._nodes[node_id] = nil
    return true
end

---Returns whether a node exists.
---@param node_id string
---@return boolean
function DirectedAcyclicGraph:has_node(node_id)
    Internals.validate_node_id(node_id, 'node_id', 2)
    return self._nodes[node_id] == true
end

---Adds a predecessor-to-successor edge and returns whether it was new.
---@param predecessor_id string
---@param successor_id string
---@return boolean inserted
function DirectedAcyclicGraph:add_edge(predecessor_id, successor_id)
    Internals.require_node(self, predecessor_id, 'predecessor_id', 2)
    Internals.require_node(self, successor_id, 'successor_id', 2)
    if predecessor_id == successor_id then
        error(('self-edge is not allowed for node %q'):format(predecessor_id), 2)
    end
    if self._outgoing[predecessor_id][successor_id] then return false end
    if Internals.reaches(self, successor_id, predecessor_id) then
        error(('edge %q -> %q would create a cycle')
            :format(predecessor_id, successor_id), 2)
    end

    self._outgoing[predecessor_id][successor_id] = true
    self._incoming[successor_id][predecessor_id] = true
    return true
end

---Removes an edge and returns whether it existed.
---@param predecessor_id string
---@param successor_id string
---@return boolean removed
function DirectedAcyclicGraph:remove_edge(predecessor_id, successor_id)
    Internals.require_node(self, predecessor_id, 'predecessor_id', 2)
    Internals.require_node(self, successor_id, 'successor_id', 2)
    if not self._outgoing[predecessor_id][successor_id] then return false end
    self._outgoing[predecessor_id][successor_id] = nil
    self._incoming[successor_id][predecessor_id] = nil
    return true
end

---Returns whether a predecessor-to-successor edge exists.
---@param predecessor_id string
---@param successor_id string
---@return boolean
function DirectedAcyclicGraph:has_edge(predecessor_id, successor_id)
    Internals.require_node(self, predecessor_id, 'predecessor_id', 2)
    Internals.require_node(self, successor_id, 'successor_id', 2)
    return self._outgoing[predecessor_id][successor_id] == true
end

---Returns a lexically sorted copy of the direct predecessor IDs.
---@param node_id string
---@return string[] predecessor_ids
function DirectedAcyclicGraph:predecessors(node_id)
    Internals.require_node(self, node_id, 'node_id', 2)
    local predecessor_ids = {}
    for predecessor_id in pairs(self._incoming[node_id]) do
        table.insert(predecessor_ids, predecessor_id)
    end
    table.sort(predecessor_ids)
    return predecessor_ids
end

---Returns a lexically sorted copy of the direct successor IDs.
---@param node_id string
---@return string[] successor_ids
function DirectedAcyclicGraph:successors(node_id)
    Internals.require_node(self, node_id, 'node_id', 2)
    local successor_ids = {}
    for successor_id in pairs(self._outgoing[node_id]) do
        table.insert(successor_ids, successor_id)
    end
    table.sort(successor_ids)
    return successor_ids
end

---Returns predecessor-before-successor order for all nodes or an induced subset.
---A supplied comparator is caller-owned policy and must define a deterministic
---strict weak order. Lexical node-ID order resolves comparator equivalence.
---@param node_ids? string[]
---@param less? fun(left: string, right: string): boolean
---@return string[] ordered_node_ids
function DirectedAcyclicGraph:topological_order(node_ids, less)
    if node_ids ~= nil and type(node_ids) ~= 'table' then
        error('node_ids must be an array when supplied', 2)
    end
    if less ~= nil and type(less) ~= 'function' then
        error('less must be a function when supplied', 2)
    end

    local selected = {}
    if node_ids then
        local entry_count = 0
        local greatest_index = 0
        for index in pairs(node_ids) do
            if type(index) ~= 'number' or index < 1 or index % 1 ~= 0 then
                error('node_ids must contain only positive integer indexes', 2)
            end
            entry_count = entry_count + 1
            greatest_index = math.max(greatest_index, index)
        end
        if entry_count ~= greatest_index then
            error('node_ids must be a contiguous array', 2)
        end
        for index = 1, entry_count do
            local node_id = node_ids[index]
            Internals.require_node(self, node_id,
                ('node_ids[%d]'):format(index), 2)
            if selected[node_id] then
                error(('duplicate node ID in node_ids: %q'):format(node_id), 2)
            end
            selected[node_id] = true
        end
    else
        for node_id in pairs(self._nodes) do selected[node_id] = true end
    end

    local indegrees = {}
    local ready = {}
    local selected_count = 0
    for node_id in pairs(selected) do
        local indegree = 0
        for predecessor_id in pairs(self._incoming[node_id]) do
            if selected[predecessor_id] then indegree = indegree + 1 end
        end
        indegrees[node_id] = indegree
        selected_count = selected_count + 1
        if indegree == 0 then table.insert(ready, node_id) end
    end

    local ordered = {}
    while #ready > 0 do
        local least_index = 1
        for index = 2, #ready do
            if Internals.comes_before(ready[index], ready[least_index], less) then
                least_index = index
            end
        end
        local node_id = table.remove(ready, least_index)
        table.insert(ordered, node_id)
        for successor_id in pairs(self._outgoing[node_id]) do
            if selected[successor_id] then
                indegrees[successor_id] = indegrees[successor_id] - 1
                if indegrees[successor_id] == 0 then
                    table.insert(ready, successor_id)
                end
            end
        end
    end

    if #ordered ~= selected_count then
        error('directed acyclic graph invariant violated during ordering', 2)
    end
    return ordered
end

return DirectedAcyclicGraph
