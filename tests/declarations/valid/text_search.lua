---Exercises every supported rendered-text search declaration.
---@return fun()
local function declaration_fixture()
    return function()
        ---@type dwarfspec.TextSearchQuery
        local root_query = {text = 'Ready'}
        local root_match = ds.search(root_query)

        local subject = ds.root()
        local subject_match = subject:search({
            text = 'Ready',
            occurrence = 2,
        })

        ---@type dwarfspec.ScreenRect
        local rectangle = {
            x1 = 1,
            y1 = 2,
            x2 = 10,
            y2 = 4,
        }
        ---@type dwarfspec.TextSearchArea
        local search_area = rectangle
        local rectangle_match = ds.search({text = 'Ready'}, search_area)

        ---@type dwarfspec.ScreenRect|nil
        local selected_match = root_match or subject_match or rectangle_match
        assert(selected_match == nil or selected_match.x2 >= selected_match.x1)
    end
end

return declaration_fixture
