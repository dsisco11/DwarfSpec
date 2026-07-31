---Supplies intentionally invalid calls for LuaLS declaration diagnostics.
---@return fun()
local function invalid_declaration_fixture()
    return function()
        ds.search({})
        ds.search({text = 42})
        ds.search({text = 'Ready', occurrence = 'first'})
        ---@type dwarfspec.TextSearchQuery
        local unknown_field_query = {text = 'Ready'}
        unknown_field_query.mode = 'pattern'
        ds.search(unknown_field_query)
        ---@type dwarfspec.ScreenRect
        local malformed_rectangle = {x1 = 1, y1 = 2, x2 = 10}
        ds.search({text = 'Ready'}, malformed_rectangle)
        ds.search({text = 'Ready'}, false)
    end
end

return invalid_declaration_fixture
