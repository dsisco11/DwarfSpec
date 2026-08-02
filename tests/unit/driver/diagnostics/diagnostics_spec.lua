-- Unit contracts for bounded live automation diagnostics.

local diagnostics_module = assert(loadfile(
    'src/dwarfspec/driver/diagnostics/diagnostics.lua'))()
local diagnostics = diagnostics_module.new({
    get_window_size=function() return 3, 2 end,
    read_tile=function(x, y)
        return {ch=65 + x + y, fg=7, bg=0, bold=false}
    end,
})

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
    it('requires explicit native screen capabilities', function()
        assert.has_error(function()
            diagnostics_module.new({read_tile=function() end})
        end, 'DwarfSpec diagnostics require get_window_size()')
        assert.has_error(function()
            diagnostics_module.new({get_window_size=function() end})
        end, 'DwarfSpec diagnostics require read_tile()')
    end)

    it('bounds recursive tree captures by depth', function()
        local tree = diagnostics.capture_view_tree(view_chain(20), {
            max_depth=3,
            max_nodes=20,
        })

        assert.same({
            max_depth=3,
            max_nodes=20,
            max_children=32,
            max_value_length=512,
            max_field_count=32,
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

    it('bounds children and diagnostic string values independently',
            function()
        local root = {
            view_id=string.rep('x', 40),
            visible=true,
            active=true,
            subviews={},
        }
        for index = 1, 10 do
            table.insert(root.subviews, {
                view_id='child-' .. index,
                visible=true,
                active=true,
                subviews={},
            })
        end

        local tree = diagnostics.capture_view_tree(root, {
            max_depth=8,
            max_nodes=20,
            max_children=3,
            max_value_length=12,
        })

        assert.equals('xxxxxxxxx...', tree.view_id)
        assert.equals(3, #tree.children)
        assert.is_true(tree.truncated)
        assert.is_true(tree.capture_bounds.truncated)
        assert.equals(3, tree.capture_bounds.max_children)
        assert.equals(12, tree.capture_bounds.max_value_length)
    end)

    it('captures bounded native screen cells through injected reads',
            function()
        local capture = diagnostics.capture_screen({
            max_width=2,
            max_height=1,
        })

        assert.equals(2, capture.width)
        assert.equals(1, capture.height)
        assert.equals(65, capture.cells[1][1].ch)
        assert.equals(66, capture.cells[1][2].ch)
    end)
end)
