-- Live acceptance for map-view positioning through the public ds command.

---Returns the raw zero-based top-left map-view origin from DFHack state.
---@return dwarfspec.MapViewPosition
local function current_view_position()
    return {
        x=df.global.window_x,
        y=df.global.window_y,
        z=df.global.window_z,
    }
end

---Returns a valid map tile distinct from the supplied position.
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
    it('aligns live map tiles to screen origins and owns exact restoration',
            function()
        assert.is_true(dfhack.isMapLoaded(),
            'map-view acceptance requires a loaded map')
        local original = ds.getViewPos(ds.EScreenOrigin.TOP_LEFT)
        assert.same(original, current_view_position())
        local dimensions = dfhack.gui.getDwarfmodeViewDims()
        local width = dimensions.map_x2 - dimensions.map_x1 + 1
        local height = dimensions.map_y2 - dimensions.map_y1 + 1
        assert.is_true(width > 0 and height > 0,
            'map-view acceptance requires positive map viewport dimensions')
        local center_offset = {
            x=math.floor(width / 2),
            y=math.floor(height / 2),
        }
        local current_center = {
            x=original.x + center_offset.x,
            y=original.y + center_offset.y,
            z=original.z,
        }
        assert.same(current_center,
            ds.getViewPos(ds.EScreenOrigin.CENTER))
        assert.same(current_center, ds.getViewPos())
        local target = alternate_view_position(current_center)
        local expected_raw = {
            x=target.x - center_offset.x,
            y=target.y - center_offset.y,
            z=target.z,
        }

        assert.same(target, ds.setViewPos(target))
        assert.same(target, ds.getViewPos(ds.EScreenOrigin.CENTER))
        assert.same(target, ds.getViewPos())
        assert.same(expected_raw,
            ds.getViewPos(ds.EScreenOrigin.TOP_LEFT))
        assert.same(expected_raw, current_view_position())
        assert.same({
            x=expected_raw.x + width - 1,
            y=expected_raw.y + height - 1,
            z=expected_raw.z,
        }, ds.getViewPos(ds.EScreenOrigin.BOTTOM_RIGHT))
        assert.is_true(ds.current_run().mount_cleanup_probe()
            .map_view_position_active)
    end)
end)
