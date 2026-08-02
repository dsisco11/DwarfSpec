-- Map-view position command bindings for one DwarfSpec run.

local M = {}

---Binds map-view position commands to the public run-scoped namespace.
---@param ds table
---@param dependencies table
function M.bind(ds, dependencies)
    local context = dependencies.context
    local cleanup_module = dependencies.cleanup_module
    local cleanup_registry = dependencies.cleanup_registry
    local origin_axes = {}
    local function add_origin(origin, x, y)
        if origin ~= nil then origin_axes[origin] = {x, y} end
    end
    add_origin(dependencies.origins.TOP_LEFT, 'start', 'start')
    add_origin(dependencies.origins.TOP, 'center', 'start')
    add_origin(dependencies.origins.TOP_RIGHT, 'finish', 'start')
    add_origin(dependencies.origins.LEFT, 'start', 'center')
    add_origin(dependencies.origins.CENTER, 'center', 'center')
    add_origin(dependencies.origins.RIGHT, 'finish', 'center')
    add_origin(dependencies.origins.BOTTOM_LEFT, 'start', 'finish')
    add_origin(dependencies.origins.BOTTOM, 'center', 'finish')
    add_origin(dependencies.origins.BOTTOM_RIGHT, 'finish', 'finish')
    local function dimensions()
        local ok, result = pcall(context.get_map_view_dimensions)
        assert(ok, 'DwarfSpec could not query the current map-view dimensions: ' .. tostring(result))
        assert(type(result) == 'table', 'DFHack returned invalid map-view dimensions')
        for _, field in ipairs({'map_x1', 'map_x2', 'map_y1', 'map_y2'}) do
            assert(type(result[field]) == 'number' and result[field] % 1 == 0,
                'DFHack returned invalid map-view dimensions')
        end
        local width, height = result.map_x2 - result.map_x1 + 1, result.map_y2 - result.map_y1 + 1
        assert(width > 0 and height > 0, 'DFHack returned invalid map-view dimensions')
        return width, height
    end
    local function offset(origin)
        origin = origin or dependencies.origins.CENTER
        local axes = origin_axes[origin]
        assert(axes, 'screen origin must be a ds.EScreenOrigin value')
        if origin == dependencies.origins.TOP_LEFT then return 0, 0 end
        local width, height = dimensions()
        local function axis(anchor, size)
            if anchor == 'start' then return 0 end
            if anchor == 'center' then return math.floor(size / 2) end
            return size - 1
        end
        return axis(axes[1], width), axis(axes[2], height)
    end
    ---Returns the map tile aligned with one origin in the current view.
    ---@param origin DwarfSpecEScreenOrigin|nil
    ---@return dwarfspec.MapViewPosition
    function ds.getViewPos(origin)
        local x_offset, y_offset = offset(origin)
        local ok, x, y, z = pcall(context.get_map_view_position)
        assert(ok, 'DwarfSpec could not query the current map-view position: ' .. tostring(x))
        for axis, value in pairs({x=x, y=y}) do
            assert(type(value) == 'number' and value % 1 == 0,
                ('DFHack returned an invalid map-view %s coordinate: %s'):format(axis, tostring(value)))
        end
        assert(type(z) == 'number' and z % 1 == 0 and z >= 0,
            'DFHack returned an invalid map-view z coordinate: ' .. tostring(z))
        return {x=x + x_offset, y=y + y_offset, z=z}
    end
    ---Aligns one map tile with a screen origin and registers restoration.
    ---@param position table
    ---@param origin DwarfSpecEScreenOrigin|nil
    ---@return table
    function ds.setViewPos(position, origin)
        assert(type(position) == 'table', 'map-view position must be a table with x, y, and z coordinates')
        for _, axis in ipairs({'x', 'y', 'z'}) do
            assert(type(position[axis]) == 'number' and position[axis] % 1 == 0 and position[axis] >= 0,
                ('map-view %s coordinate must be a nonnegative integer'):format(axis))
        end
        local x_offset, y_offset = offset(origin)
        if context.map_view_cleanup_entry == nil then
            local original = ds.getViewPos(dependencies.origins.TOP_LEFT)
            context.map_view_cleanup_entry = cleanup_module.push(cleanup_registry,
                'restore map-view position', function()
                    local restored = context.set_map_view_position(original.x, original.y, original.z)
                    assert(restored ~= false, 'DFHack rejected the original map-view position')
                    context.map_view_cleanup_entry = nil
                end)
        end
        local ok, accepted = pcall(context.set_map_view_position,
            position.x - x_offset, position.y - y_offset, position.z)
        assert(ok, 'DwarfSpec could not set the map-view position: ' .. tostring(accepted))
        assert(accepted ~= false, 'DFHack rejected the requested map-view position')
        return {x=position.x, y=position.y, z=position.z}
    end
end

return M
