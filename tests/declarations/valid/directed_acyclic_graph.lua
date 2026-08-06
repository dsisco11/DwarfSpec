---Exercises the public DirectedAcyclicGraph declaration surface.
---@return fun()
local function declaration_fixture()
    return function()
        local DirectedAcyclicGraph = require(
            'dwarfspec.graphs.directed_acyclic_graph')
        ---@type dwarfspec.DirectedAcyclicGraph
        local graph = DirectedAcyclicGraph.new()
        local less = function(left, right) return left < right end

        assert(graph:add_node('a'))
        assert(graph:add_node('b'))
        assert(graph:has_node('a'))
        assert(graph:add_edge('a', 'b'))
        assert(graph:has_edge('a', 'b'))
        local predecessors = graph:predecessors('b')
        local successors = graph:successors('a')
        local order = graph:topological_order({'a', 'b'}, less)
        assert(#predecessors == 1 and #successors == 1 and #order == 2)
        assert(graph:remove_edge('a', 'b'))
        assert(graph:remove_node('a'))
    end
end

return declaration_fixture
