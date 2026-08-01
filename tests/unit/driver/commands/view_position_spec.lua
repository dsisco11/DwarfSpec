local command = require('dwarfspec.driver.commands.view_position')

describe('view-position command binding', function()
    it('applies the requested origin offset to a map position', function()
        local ds = {}
        command.bind(ds, {origins={TOP_LEFT='top_left', CENTER='center'},
            context={get_map_view_dimensions=function()
                return {map_x1=0, map_x2=4, map_y1=0, map_y2=2}
            end, get_map_view_position=function() return 10, 20, 3 end},
            cleanup_module={}, cleanup_registry={}})
        assert.same({x=12, y=21, z=3}, ds.getViewPos('center'))
    end)
end)
