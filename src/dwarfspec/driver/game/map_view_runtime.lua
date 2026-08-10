-- Cohesive run-scoped map-view access and origin conversion.

local ORIGIN_AXES = {
    top_left={'start', 'start'},
    top={'center', 'start'},
    top_right={'finish', 'start'},
    left={'start', 'center'},
    center={'center', 'center'},
    right={'finish', 'center'},
    bottom_left={'start', 'finish'},
    bottom={'center', 'finish'},
    bottom_right={'finish', 'finish'},
}

---@class dwarfspec.MapViewRuntime
---@field private _read fun():integer, integer, integer
---@field private _write fun(x:integer, y:integer, z:integer):any
---@field private _dimensions fun():table
---@field private _origins table
local MapViewRuntime = {}
MapViewRuntime.__index = MapViewRuntime

---Creates map-view runtime support for one assembled run.
---@param options table
---@return dwarfspec.MapViewRuntime
function MapViewRuntime.new(options)
    assert(type(options) == 'table', 'map-view runtime options are required')
    for _, name in ipairs({'read', 'write', 'dimensions'}) do
        assert(type(options[name]) == 'function',
            'map-view runtime requires ' .. name)
    end
    assert(type(options.origins) == 'table',
        'map-view runtime requires screen origins')
    return setmetatable({_read=options.read, _write=options.write,
        _dimensions=options.dimensions, _origins=options.origins},
        MapViewRuntime)
end

---Returns one axis offset for a viewport anchor.
---@param anchor string
---@param size integer
---@return integer
function MapViewRuntime:_axis_offset(anchor, size)
    if anchor == 'start' then return 0 end
    if anchor == 'center' then return math.floor(size / 2) end
    return size - 1
end

---Returns the validated offset for one public screen origin.
---@param origin any
---@return integer, integer
function MapViewRuntime:origin_offset(origin)
    origin = origin or self._origins.CENTER
    local name
    for candidate, value in pairs(self._origins) do
        if value == origin then name = candidate:lower() break end
    end
    local axes = name and ORIGIN_AXES[name]
    assert(axes, 'screen origin must be a ds.EScreenOrigin value')
    if origin == self._origins.TOP_LEFT then return 0, 0 end
    local ok, dimensions = pcall(self._dimensions)
    assert(ok, 'DwarfSpec could not query the current map-view dimensions: ' ..
        tostring(dimensions))
    assert(type(dimensions) == 'table',
        'DFHack returned invalid map-view dimensions')
    for _, field in ipairs({'map_x1', 'map_x2', 'map_y1', 'map_y2'}) do
        assert(type(dimensions[field]) == 'number' and
                dimensions[field] % 1 == 0,
            'DFHack returned invalid map-view dimensions')
    end
    local width = dimensions.map_x2 - dimensions.map_x1 + 1
    local height = dimensions.map_y2 - dimensions.map_y1 + 1
    assert(width > 0 and height > 0,
        'DFHack returned invalid map-view dimensions')
    return self:_axis_offset(axes[1], width),
        self:_axis_offset(axes[2], height)
end

---Reads the current map position aligned with one public origin.
---@param origin any
---@return table
function MapViewRuntime:get_position(origin)
    local offset_x, offset_y = self:origin_offset(origin)
    local ok, x, y, z = pcall(self._read)
    assert(ok, 'DwarfSpec could not query the current map-view position: ' ..
        tostring(x))
    for axis, value in pairs({x=x, y=y}) do
        assert(type(value) == 'number' and value % 1 == 0,
            ('DFHack returned an invalid map-view %s coordinate: %s')
                :format(axis, tostring(value)))
    end
    assert(type(z) == 'number' and z % 1 == 0 and z >= 0,
        ('DFHack returned an invalid map-view z coordinate: %s')
            :format(tostring(z)))
    return {x=x + offset_x, y=y + offset_y, z=z}
end

---Writes one raw top-left map-view position.
---@param x integer
---@param y integer
---@param z integer
---@return any
function MapViewRuntime:set_position(x, y, z)
    return self._write(x, y, z)
end

---Returns the explicit top-left origin token.
---@return any
function MapViewRuntime:top_left_origin()
    return self._origins.TOP_LEFT
end

return MapViewRuntime
