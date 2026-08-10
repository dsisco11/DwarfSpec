local MapViewRuntime = require('dwarfspec.driver.game.map_view_runtime')

describe('map view runtime capability', function()
    it('converts origins while preserving raw read and write ownership', function()
        local written
        local runtime = MapViewRuntime.new({
            read=function() return 10, 20, 3 end,
            write=function(x, y, z) written={x=x, y=y, z=z} return true end,
            dimensions=function()
                return {map_x1=2, map_x2=10, map_y1=4, map_y2=10}
            end,
            origins={TOP_LEFT='top-left', CENTER='center',
                BOTTOM_RIGHT='bottom-right'},
        })

        assert.same({x=14, y=23, z=3}, runtime:get_position('center'))
        assert.same({8, 6}, {runtime:origin_offset('bottom-right')})
        assert.equal('top-left', runtime:top_left_origin())
        assert.is_true(runtime:set_position(1, 2, 3))
        assert.same({x=1, y=2, z=3}, written)
    end)

    it('rejects unknown origin values', function()
        local runtime = MapViewRuntime.new({read=function() return 0, 0, 0 end,
            write=function() return true end,
            dimensions=function() return {} end,
            origins={TOP_LEFT='top-left', CENTER='center'}})
        assert.has_error(function() runtime:origin_offset('unknown') end,
            'screen origin must be a ds.EScreenOrigin value')
    end)
end)
