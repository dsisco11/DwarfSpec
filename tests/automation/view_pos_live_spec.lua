-- Live acceptance for map-view positioning through the public ds command.

---Returns the current zero-based map-view origin from DFHack global state.
---@return dwarfspec.MapViewPosition
local function current_view_position()
    return {
        x=df.global.window_x,
        y=df.global.window_y,
        z=df.global.window_z,
    }
end

---Returns a valid map-view origin distinct from the supplied position.
---@param position dwarfspec.MapViewPosition
---@return dwarfspec.MapViewPosition
local function alternate_view_position(position)
    local map = assert(df.global.world and df.global.world.map,
        'map-view acceptance requires a loaded map')
    assert(map.x_count > 1 or map.y_count > 1 or map.z_count > 1,
        'map-view acceptance requires a map with more than one tile')
    if map.x_count > 1 then
        return {x=(position.x + 1) % map.x_count, y=position.y,
            z=position.z}
    end
    if map.y_count > 1 then
        return {x=position.x, y=(position.y + 1) % map.y_count,
            z=position.z}
    end
    return {x=position.x, y=position.y, z=(position.z + 1) % map.z_count}
end

describe('map-view position command', function()
    it('moves the live map view and preserves automatic restoration ownership',
            function()
        assert.is_true(dfhack.isMapLoaded(),
            'map-view acceptance requires a loaded map')
        local original = ds.getViewPos()
        assert.same(original, current_view_position())
        local target = alternate_view_position(original)

        assert.same(target, ds.setViewPos(target))
        assert.same(target, ds.getViewPos())
        assert.same(target, current_view_position())
        assert.is_true(ds.current_run().mount_cleanup_probe()
            .map_view_position_active)

        assert.same(original, ds.setViewPos(original))
        assert.same(original, ds.getViewPos())
        assert.same(original, current_view_position())
    end)
end)
