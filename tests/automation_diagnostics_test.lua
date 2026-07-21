-- Unit contracts for bounded live automation diagnostics.

local diagnostics = assert(loadfile(
    'tests/automation/support/diagnostics.lua'))()

---Builds a single-child view chain with stable propagated IDs.
---@param count integer
---@return table
local function view_chain(count)
    local root = {view_id='node-1', visible=true, active=true, subviews={}}
    local current = root
    for index = 2, count do
        local child = {
            view_id='node-' .. index,
            visible=true,
            active=true,
            subviews={},
        }
        table.insert(current.subviews, child)
        current = child
    end
    return root
end

describe('automation mount diagnostics', function()
    it('bounds recursive tree captures by depth', function()
        local tree = diagnostics.capture_view_tree(view_chain(20), {
            max_depth=3,
            max_nodes=20,
        })

        assert.same({
            max_depth=3,
            max_nodes=20,
            node_count=4,
            truncated=true,
        }, tree.capture_bounds)
        assert.is_true(tree.children[1].children[1].children[1].truncated)
        assert.equals(0,
            #tree.children[1].children[1].children[1].children)
    end)

    it('bounds wide tree captures by total node count', function()
        local root = {view_id='root', visible=true, active=true, subviews={}}
        for index = 1, 20 do
            table.insert(root.subviews, {
                view_id='child-' .. index,
                visible=true,
                active=true,
                subviews={},
            })
        end

        local tree = diagnostics.capture_view_tree(root, {
            max_depth=8,
            max_nodes=5,
        })

        assert.equals(5, tree.capture_bounds.node_count)
        assert.is_true(tree.capture_bounds.truncated)
        assert.is_true(tree.truncated)
        assert.equals(4, #tree.children)
    end)
end)
