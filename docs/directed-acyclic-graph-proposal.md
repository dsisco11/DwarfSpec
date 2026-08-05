# Directed acyclic graph utility proposal

## Status

This document proposes a small domain-neutral directed acyclic graph utility.
It is a prerequisite for the resource-dependency and cleanup-ordering work in
the verified command execution architecture. It is an architecture proposal,
not an implementation checklist and not a description of shipped behavior.

## Objective

Provide one reusable, deterministic `DirectedAcyclicGraph` implementation so
resource and cleanup systems do not implement their own edge storage, cycle
detection, neighbor lookup, or topological ordering.

The utility must be quick to implement and exhaustively unit test. Domain
policy remains outside it.

## Boundary

`DirectedAcyclicGraph` knows only stable node IDs and directed edges. An edge
`A -> B` means that A precedes B. Callers assign domain meaning such as
"prerequisite to dependent."

The utility does:

- add and remove nodes;
- add and remove directed edges;
- reject self-edges, unknown endpoints, and cycles;
- report direct incoming and outgoing neighbors; and
- return deterministic topological order for all nodes or an induced subset.

The utility does not know about:

- resource claims, owners, lifetimes, or compatible sharing;
- cleanup transactions, LIFO policy, or reverse-topological execution;
- commands, suites, tests, service runs, journals, or result projections;
- persistence, serialization, concurrency, or thread safety;
- node payloads, implicit node creation, transitive reduction, or graph
  visualization.

`ResourceDependencyIndex` owns resource and lifetime policy.
`CleanupPlanner` requests topological order and reverses it for cleanup, with
its own tie-breaking and eligibility rules.

## Location and shape

Implement the utility as:

```text
src/dwarfspec/support/directed_acyclic_graph.lua
tests/unit/support/directed_acyclic_graph_spec.lua
```

The module exports one `DirectedAcyclicGraph` class. Its internal representation
is private. Node IDs are non-empty strings; domain objects and mutable payloads
remain in the caller.

```lua
---@class dwarfspec.DirectedAcyclicGraph
local DirectedAcyclicGraph = {}
DirectedAcyclicGraph.__index = DirectedAcyclicGraph

---Creates an empty graph.
---@return dwarfspec.DirectedAcyclicGraph
function DirectedAcyclicGraph.new() end

---Adds a node and returns whether it was newly inserted.
---@param node_id string
---@return boolean inserted
function DirectedAcyclicGraph:add_node(node_id) end

---Removes a node and all incident edges.
---@param node_id string
---@return boolean removed
function DirectedAcyclicGraph:remove_node(node_id) end

---Returns whether a node exists.
---@param node_id string
---@return boolean
function DirectedAcyclicGraph:has_node(node_id) end

---Adds predecessor-to-successor edge and returns whether it was new.
---@param predecessor_id string
---@param successor_id string
---@return boolean inserted
function DirectedAcyclicGraph:add_edge(predecessor_id, successor_id) end

---Removes an edge and returns whether it existed.
---@param predecessor_id string
---@param successor_id string
---@return boolean removed
function DirectedAcyclicGraph:remove_edge(predecessor_id, successor_id) end

---Returns whether an edge exists.
---@param predecessor_id string
---@param successor_id string
---@return boolean
function DirectedAcyclicGraph:has_edge(predecessor_id, successor_id) end

---Returns a lexically sorted copy of the direct predecessor IDs.
---@param node_id string
---@return string[] predecessor_ids
function DirectedAcyclicGraph:predecessors(node_id) end

---Returns a lexically sorted copy of the direct successor IDs.
---@param node_id string
---@return string[] successor_ids
function DirectedAcyclicGraph:successors(node_id) end

---Returns predecessor-before-successor order for all nodes or an induced subset.
---@param node_ids? string[]
---@param less? fun(left: string, right: string): boolean
---@return string[] ordered_node_ids
function DirectedAcyclicGraph:topological_order(node_ids, less) end

return DirectedAcyclicGraph
```

All public methods validate node IDs as non-empty strings. Neighbor queries and
edge operations reject unknown node IDs. `topological_order()` rejects duplicate
or unknown IDs in a supplied subset. These are internal programming errors and
raise descriptive errors rather than returning domain failures.
The optional comparator must be a function when supplied.

Adding an existing node or edge is an idempotent no-op and returns `false`.
Removing an absent node or edge is an idempotent no-op and returns `false`,
provided every explicitly supplied endpoint is a valid known node. Removing a
node removes all of its incoming and outgoing edges atomically.

## Ordering contract

`topological_order()` uses Kahn's algorithm over the selected induced graph:

1. Compute selected-node indegrees from edges whose endpoints are both
   selected.
2. Repeatedly select the least ready node.
3. Emit it and decrement its selected successors.

The default ordering compares node IDs lexically. A caller may provide
`less(left, right)` for domain-specific deterministic tie-breaking. A supplied
comparator must define a deterministic strict weak order. When neither node
compares before the other, lexical node-ID order is the mandatory fallback.
The comparator is used only between simultaneously ready nodes; it cannot
violate an edge.

The method returns a new array. Neighbor queries also return new arrays. Callers
cannot mutate graph state through returned collections.

The full graph is always acyclic because `add_edge()` checks whether the proposed
successor already reaches the proposed predecessor before committing the
edge. A failed insertion leaves the graph unchanged.

## Complexity

Favor straightforward adjacency maps over caching:

- node and edge membership: expected O(1);
- node removal: O(V + E) in the intentionally simple implementation;
- edge insertion with cycle detection: O(V + E);
- neighbor query: O(degree log degree) for sorted output; and
- topological ordering: O(V^2 + E) with a simple sorted ready-node array.

DwarfSpec run graphs are expected to be small. Avoiding cache invalidation and
specialized data structures is more valuable than optimizing these bounds.

## Unit-test contract

The focused suite must cover:

- empty construction and empty ordering;
- node insertion, duplicate insertion, membership, removal, and duplicate
  removal;
- edge insertion, duplicate insertion, membership, removal, and duplicate
  removal;
- rejection of nil, non-string, and empty IDs by every public method that
  accepts node IDs;
- rejection of unknown endpoints, self-edges, and direct or indirect cycles;
- proof that rejected edges do not mutate the graph;
- direct predecessor and successor queries with lexical ordering;
- node removal clearing every incident edge;
- predecessor-before-successor ordering for chains, forks, diamonds, and
  disconnected nodes;
- lexical ordering of simultaneously ready nodes;
- custom deterministic ordering of simultaneously ready nodes;
- lexical fallback when the custom comparator treats ready nodes as equivalent;
- rejection of a supplied comparator that is not a function;
- induced-subset ordering, including edges that cross the subset boundary;
- rejection of duplicate or unknown subset IDs; and
- proof that mutating returned arrays does not mutate the graph.

No DFHack process, scheduler, filesystem fixture, service, or cleanup registry
is required. The suite is a pure Lua unit test and should run in well under one
second.

Qualification of this prerequisite requires only its focused unit suite and
the repository's ordinary Lua syntax, formatting, and declaration checks. It
does not require the full unit suite, live automation, service validation, or
consumer integration tests. Those belong to the later proposal work that wires
in `ResourceDependencyIndex` and `CleanupPlanner`.

## Completion criteria

This prerequisite is complete when:

- the module and declarations implement exactly the API above;
- every unit-test contract case passes;
- Lua syntax, formatting, and declaration checks pass for the new files; and
- design review confirms that the API exposes the generic operations required
  by the documented `ResourceDependencyIndex` and `CleanupPlanner` contracts
  without adding domain-specific methods. Actual consumer wiring and integration
  tests belong to those later proposals and do not gate this prerequisite.
