-- Unit contracts for the domain-neutral directed acyclic graph utility.

local DirectedAcyclicGraph = require('dwarfspec.graphs.directed_acyclic_graph')

---Creates a graph containing each supplied node ID.
---@param node_ids string[]
---@return dwarfspec.DirectedAcyclicGraph
local function graph_with_nodes(node_ids)
    local graph = DirectedAcyclicGraph.new()
    for _, node_id in ipairs(node_ids) do
        assert.is_true(graph:add_node(node_id))
    end
    return graph
end

---Asserts that a function raises an error containing the expected text.
---@param callback fun()
---@param expected_text string
local function assert_error(callback, expected_text)
    local succeeded, message = pcall(callback)
    assert.is_false(succeeded)
    assert.is_truthy(tostring(message):find(expected_text, 1, true))
end

describe('DirectedAcyclicGraph nodes', function()
    it('constructs an empty graph and orders it as empty', function()
        local graph = DirectedAcyclicGraph.new()
        assert.same({}, graph:topological_order())
    end)

    it('inserts, queries, and idempotently removes nodes', function()
        local graph = DirectedAcyclicGraph.new()
        assert.is_true(graph:add_node('alpha'))
        assert.is_false(graph:add_node('alpha'))
        assert.is_true(graph:has_node('alpha'))
        assert.is_true(graph:remove_node('alpha'))
        assert.is_false(graph:remove_node('alpha'))
        assert.is_false(graph:has_node('alpha'))
    end)

    it('removes every incoming and outgoing edge with a node', function()
        local graph = graph_with_nodes({'a', 'b', 'c'})
        graph:add_edge('a', 'b')
        graph:add_edge('b', 'c')
        graph:remove_node('b')
        assert.same({'a', 'c'}, graph:topological_order())
        assert.same({}, graph:successors('a'))
        assert.same({}, graph:predecessors('c'))
    end)
end)

describe('DirectedAcyclicGraph edges', function()
    it('inserts, queries, and idempotently removes edges', function()
        local graph = graph_with_nodes({'a', 'b'})
        assert.is_true(graph:add_edge('a', 'b'))
        assert.is_false(graph:add_edge('a', 'b'))
        assert.is_true(graph:has_edge('a', 'b'))
        assert.is_true(graph:remove_edge('a', 'b'))
        assert.is_false(graph:remove_edge('a', 'b'))
        assert.is_false(graph:has_edge('a', 'b'))
    end)

    it('rejects invalid endpoints and self-edges', function()
        local graph = graph_with_nodes({'a', 'b'})
        assert_error(function() graph:add_edge('missing', 'a') end, 'unknown')
        assert_error(function() graph:add_edge('a', 'missing') end, 'unknown')
        assert_error(function() graph:remove_edge('missing', 'a') end, 'unknown')
        assert_error(function() graph:remove_edge('a', 'missing') end, 'unknown')
        assert_error(function() graph:has_edge('missing', 'a') end, 'unknown')
        assert_error(function() graph:has_edge('a', 'missing') end, 'unknown')
        assert_error(function() graph:add_edge('a', 'a') end, 'self-edge')
        assert.same({'a', 'b'}, graph:topological_order())
        assert.same({}, graph:successors('a'))
        assert.same({}, graph:predecessors('b'))
    end)

    it('rejects direct and indirect cycles without mutating state', function()
        local graph = graph_with_nodes({'a', 'b', 'c'})
        graph:add_edge('a', 'b')
        graph:add_edge('b', 'c')
        assert_error(function() graph:add_edge('c', 'a') end, 'cycle')
        assert_error(function() graph:add_edge('b', 'a') end, 'cycle')
        assert.same({'a', 'b', 'c'}, graph:topological_order())
        assert.same({'b'}, graph:successors('a'))
        assert.same({'c'}, graph:successors('b'))
        assert.same({}, graph:successors('c'))
    end)
end)

describe('DirectedAcyclicGraph validation and query isolation', function()
    it('rejects nil, non-string, and empty node IDs at every node-ID input',
            function()
        local graph = graph_with_nodes({'a', 'b'})
        local invalid_ids = {1, ''}
        for _, node_id in ipairs(invalid_ids) do
            assert_error(function() graph:add_node(node_id) end, 'nonempty')
            assert_error(function() graph:remove_node(node_id) end, 'nonempty')
            assert_error(function() graph:has_node(node_id) end, 'nonempty')
            assert_error(function() graph:add_edge(node_id, 'a') end, 'nonempty')
            assert_error(function() graph:add_edge('a', node_id) end, 'nonempty')
            assert_error(function() graph:remove_edge(node_id, 'a') end, 'nonempty')
            assert_error(function() graph:remove_edge('a', node_id) end, 'nonempty')
            assert_error(function() graph:has_edge(node_id, 'a') end, 'nonempty')
            assert_error(function() graph:has_edge('a', node_id) end, 'nonempty')
            assert_error(function() graph:predecessors(node_id) end, 'nonempty')
            assert_error(function() graph:successors(node_id) end, 'nonempty')
            assert_error(function() graph:topological_order({node_id}) end,
                'nonempty')
        end
        assert_error(function() graph:add_node(nil) end, 'nonempty')
        assert_error(function() graph:remove_node(nil) end, 'nonempty')
        assert_error(function() graph:has_node(nil) end, 'nonempty')
        assert_error(function() graph:add_edge(nil, 'a') end, 'nonempty')
        assert_error(function() graph:add_edge('a', nil) end, 'nonempty')
        assert_error(function() graph:remove_edge(nil, 'a') end, 'nonempty')
        assert_error(function() graph:remove_edge('a', nil) end, 'nonempty')
        assert_error(function() graph:has_edge(nil, 'a') end, 'nonempty')
        assert_error(function() graph:has_edge('a', nil) end, 'nonempty')
        assert_error(function() graph:predecessors(nil) end, 'nonempty')
        assert_error(function() graph:successors(nil) end, 'nonempty')
    end)

    it('rejects unknown node queries and malformed ordering inputs', function()
        local graph = graph_with_nodes({'a'})
        assert_error(function() graph:predecessors('missing') end, 'unknown')
        assert_error(function() graph:successors('missing') end, 'unknown')
        assert_error(function() graph:topological_order(nil, true) end,
            'function')
        assert_error(function() graph:topological_order({'a', 'a'}) end,
            'duplicate')
        assert_error(function() graph:topological_order({'missing'}) end,
            'unknown')
    end)

    it('returns lexical, detached neighbor arrays', function()
        local graph = graph_with_nodes({'a', 'b', 'c', 'd'})
        graph:add_edge('c', 'd')
        graph:add_edge('a', 'd')
        graph:add_edge('d', 'b')
        local predecessors = graph:predecessors('d')
        local successors = graph:successors('d')
        assert.same({'a', 'c'}, predecessors)
        assert.same({'b'}, successors)
        predecessors[1] = 'changed'
        successors[1] = 'changed'
        assert.same({'a', 'c'}, graph:predecessors('d'))
        assert.same({'b'}, graph:successors('d'))
    end)
end)

describe('DirectedAcyclicGraph ordering', function()
    it('preserves chains, forks, diamonds, and disconnected nodes', function()
        local graph = graph_with_nodes({'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h'})
        graph:add_edge('a', 'b')
        graph:add_edge('b', 'c')
        graph:add_edge('d', 'e')
        graph:add_edge('d', 'f')
        graph:add_edge('e', 'g')
        graph:add_edge('f', 'g')
        local order = graph:topological_order()
        local positions = {}
        for index, node_id in ipairs(order) do positions[node_id] = index end
        assert.is_true(positions.a < positions.b and positions.b < positions.c)
        assert.is_true(positions.d < positions.e and positions.d < positions.f)
        assert.is_true(positions.e < positions.g and positions.f < positions.g)
        assert.equals(8, #order)
    end)

    it('uses lexical order by default and custom order only for ready nodes',
            function()
        local graph = graph_with_nodes({'a', 'b', 'c'})
        graph:add_edge('a', 'c')
        graph:add_edge('b', 'c')
        assert.same({'a', 'b', 'c'}, graph:topological_order())
        local reverse = function(left, right) return left > right end
        assert.same({'b', 'a', 'c'}, graph:topological_order(nil, reverse))
    end)

    it('is stable for strict weak ordering and falls back lexically on ties',
            function()
        local graph = graph_with_nodes({'a1', 'a2', 'b1', 'b2'})
        local by_group = function(left, right)
            return left:sub(1, 1) < right:sub(1, 1)
        end
        local first = graph:topological_order(nil, by_group)
        assert.same({'a1', 'a2', 'b1', 'b2'}, first)
        assert.same(first, graph:topological_order(nil, by_group))
    end)

    it('orders induced subsets independently of crossing edges and detaches orders',
            function()
        local graph = graph_with_nodes({'a', 'b', 'c', 'd'})
        graph:add_edge('a', 'b')
        graph:add_edge('b', 'c')
        graph:add_edge('c', 'd')
        local order = graph:topological_order({'d', 'b', 'c'})
        assert.same({'b', 'c', 'd'}, order)
        order[1] = 'changed'
        assert.same({'b', 'c', 'd'}, graph:topological_order({'d', 'b', 'c'}))
        assert.same({'a', 'b', 'c', 'd'}, graph:topological_order())
    end)
end)
