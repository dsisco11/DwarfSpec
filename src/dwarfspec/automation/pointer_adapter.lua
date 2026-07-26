-- Production reversible virtual pointer adapter for live automation.

local EPointerSpace = require('dwarfspec.pointer_spaces')

local M = {}

---Validated effective runtime grid and pixel geometry.
---@class DwarfSpecPointerGeometry
---@field grid_width integer
---@field grid_height integer
---@field pixel_width integer
---@field pixel_height integer
---@field cell_pixel_width integer
---@field cell_pixel_height integer

---One zero-based coordinate in a declared pointer space.
---@class DwarfSpecPointerCoordinate
---@field x integer
---@field y integer

---One logical pointer position represented in both coordinate systems.
---@class DwarfSpecPointerPosition
---@field grid DwarfSpecPointerCoordinate
---@field pixels DwarfSpecPointerCoordinate

---Injected boundaries used by the pointer adapter.
---@class DwarfSpecPointerAdapterDependencies
---@field get_geometry? fun():DwarfSpecPointerGeometry

local GEOMETRY_FIELDS = {
    {name='grid_width', gps_name='dimx'},
    {name='grid_height', gps_name='dimy'},
    {name='pixel_width', gps_name='screen_pixel_x'},
    {name='pixel_height', gps_name='screen_pixel_y'},
    {name='cell_pixel_width', gps_name='tile_pixel_x'},
    {name='cell_pixel_height', gps_name='tile_pixel_y'},
}

---Creates an inactive pointer adapter scoped to one cleanup registry.
---@param cleanup_module table
---@param cleanup_registry table
---@param dependencies DwarfSpecPointerAdapterDependencies|nil
---@return table
function M.new(cleanup_module, cleanup_registry, dependencies)
    dependencies = dependencies or {}
    return {
        cleanup_module=cleanup_module,
        cleanup_registry=cleanup_registry,
        get_geometry=dependencies.get_geometry,
        x=nil,
        y=nil,
        original_get_mouse_pos=nil,
        patched_get_mouse_pos=nil,
        cleanup_entry=nil,
        original_button_state=nil,
        button_cleanup_entry=nil,
    }
end

---Validates and copies one effective runtime pointer geometry.
---@param geometry table
---@return DwarfSpecPointerGeometry
function M.validate_geometry(geometry)
    assert(type(geometry) == 'table',
        'pointer geometry must be a table')
    local validated = {}
    for _, field in ipairs(GEOMETRY_FIELDS) do
        local value = geometry[field.name]
        assert(type(value) == 'number' and value % 1 == 0 and value > 0,
            ('pointer geometry gps.%s must be a positive integer; got %s')
                :format(field.gps_name, tostring(value)))
        validated[field.name] = value
    end
    return validated
end

---Reads and validates fresh effective geometry from the injected provider.
---@param adapter table
---@return DwarfSpecPointerGeometry
function M.geometry(adapter)
    assert(type(adapter.get_geometry) == 'function',
        'pointer adapter requires an effective-geometry provider')
    return M.validate_geometry(adapter.get_geometry())
end

---Validates one zero-based pointer coordinate against its current bound.
---@param value any
---@param space string
---@param axis string
---@param bound integer
local function validate_coordinate(value, space, axis, bound)
    assert(type(value) == 'number' and value % 1 == 0,
        ('%s %s coordinate must be an integer; got %s')
            :format(space, axis, tostring(value)))
    assert(value >= 0 and value < bound,
        ('%s %s coordinate %s is outside [0, %d]')
            :format(space, axis, tostring(value), bound - 1))
end

---Normalizes grid or pixel input into one paired logical pointer position.
---@param x any
---@param y any
---@param space string
---@param geometry DwarfSpecPointerGeometry
---@return DwarfSpecPointerPosition
function M.normalize_position(x, y, space, geometry)
    geometry = M.validate_geometry(geometry)
    if space == EPointerSpace.GRID then
        validate_coordinate(x, 'grid', 'x', geometry.grid_width)
        validate_coordinate(y, 'grid', 'y', geometry.grid_height)
        return {
            grid={x=x, y=y},
            pixels={
                x=x * geometry.cell_pixel_width +
                    math.floor(geometry.cell_pixel_width / 2),
                y=y * geometry.cell_pixel_height +
                    math.floor(geometry.cell_pixel_height / 2),
            },
        }
    end
    if space == EPointerSpace.PIXELS then
        validate_coordinate(x, 'pixels', 'x', geometry.pixel_width)
        validate_coordinate(y, 'pixels', 'y', geometry.pixel_height)
        return {
            grid={
                x=math.min(math.floor(x / geometry.cell_pixel_width),
                    geometry.grid_width - 1),
                y=math.min(math.floor(y / geometry.cell_pixel_height),
                    geometry.grid_height - 1),
            },
            pixels={x=x, y=y},
        }
    end
    error('unsupported pointer coordinate space: ' .. tostring(space), 2)
end

---Restores the original pointer function and rejects conflicting patches.
---@param adapter table
local function restore(adapter)
    if not adapter.patched_get_mouse_pos then return end
    if dfhack.screen.getMousePos ~= adapter.patched_get_mouse_pos then
        error('automation pointer restoration refused: getMousePos changed externally')
    end
    dfhack.screen.getMousePos = adapter.original_get_mouse_pos
    adapter.original_get_mouse_pos = nil
    adapter.patched_get_mouse_pos = nil
    adapter.x = nil
    adapter.y = nil
end

---Installs or updates the virtual interface pointer position.
---@param adapter table
---@param x integer
---@param y integer
function M.set(adapter, x, y)
    assert(type(x) == 'number' and x % 1 == 0,
        'pointer x coordinate must be an integer')
    assert(type(y) == 'number' and y % 1 == 0,
        'pointer y coordinate must be an integer')
    if not adapter.patched_get_mouse_pos then
        adapter.original_get_mouse_pos = dfhack.screen.getMousePos
        adapter.patched_get_mouse_pos = function()
            return adapter.x, adapter.y
        end
        dfhack.screen.getMousePos = adapter.patched_get_mouse_pos
        adapter.cleanup_entry = adapter.cleanup_module.push(
            adapter.cleanup_registry, 'virtual pointer', function()
                restore(adapter)
            end)
    end
    adapter.x = x
    adapter.y = y
end

---Returns the active virtual pointer position.
---@param adapter table
---@return integer, integer
function M.position(adapter)
    assert(adapter.patched_get_mouse_pos,
        'mouse input requires a pointer position; call ds.move_pointer() ' ..
        'or subject:hover() first')
    return adapter.x, adapter.y
end

---Removes the virtual pointer adapter immediately.
---@param adapter table
function M.clear(adapter)
    if not adapter.patched_get_mouse_pos then return end
    restore(adapter)
    adapter.cleanup_module.release(adapter.cleanup_registry,
        adapter.cleanup_entry)
    adapter.cleanup_entry = nil
end

---Runs one input operation with temporary native interface mouse coordinates.
---@param x integer
---@param y integer
---@param operation function
---@return any
function M.with_interface_mouse(x, y, operation)
    local gps = df.global.gps
    local enabler = df.global.enabler
    local original_x = gps.mouse_x
    local original_y = gps.mouse_y
    local original_mouse_focus = enabler and enabler.mouse_focus
    local original_tracking_on = enabler and enabler.tracking_on
    gps.mouse_x = x
    gps.mouse_y = y
    if enabler then
        enabler.mouse_focus = true
        enabler.tracking_on = 1
    end
    local ok, first, second, third = xpcall(operation, debug.traceback)
    gps.mouse_x = original_x
    gps.mouse_y = original_y
    if enabler then
        enabler.mouse_focus = original_mouse_focus
        enabler.tracking_on = original_tracking_on
    end
    if not ok then error(first, 0) end
    return first, second, third
end

local BUTTON_STATE_FIELDS = {
    'mouse_focus',
    'tracking_on',
    'mouse_lbut_down',
    'mouse_lbut_lift',
    'mouse_rbut_down',
    'mouse_rbut_lift',
    'mouse_mbut_down',
    'mouse_mbut_lift',
}

---Claims the native button state and registers run-scoped restoration.
---@param adapter table
local function claim_button_state(adapter)
    if adapter.button_cleanup_entry then return end
    local enabler = df.global.enabler
    local original = {}
    for _, field in ipairs(BUTTON_STATE_FIELDS) do
        original[field] = enabler[field]
    end
    adapter.original_button_state = original
    adapter.button_cleanup_entry = adapter.cleanup_module.push(
        adapter.cleanup_registry, 'mouse button state', function()
            for _, field in ipairs(BUTTON_STATE_FIELDS) do
                enabler[field] = original[field]
            end
            adapter.original_button_state = nil
            adapter.button_cleanup_entry = nil
        end)
end

---Dispatches one persistent button-down or button-up state transition.
---@param adapter table
---@param down_field string
---@param lift_field string
---@param is_down boolean
---@param operation function
---@return any
function M.with_button_state(adapter, down_field, lift_field, is_down,
        operation)
    claim_button_state(adapter)
    local enabler = df.global.enabler
    local previous_down = enabler[down_field]
    local previous_lift = enabler[lift_field]
    local previous_mouse_focus = enabler.mouse_focus
    local previous_tracking_on = enabler.tracking_on
    enabler.mouse_focus = true
    enabler.tracking_on = 1
    enabler[down_field] = is_down and 1 or 0
    enabler[lift_field] = is_down and 0 or 1
    local ok, first, second, third = xpcall(operation, debug.traceback)
    if ok then
        enabler[lift_field] = 0
        if not is_down and enabler.mouse_lbut_down == 0 and
                enabler.mouse_rbut_down == 0 and
                enabler.mouse_mbut_down == 0 then
            enabler.mouse_focus = adapter.original_button_state.mouse_focus
            enabler.tracking_on = adapter.original_button_state.tracking_on
        end
    else
        enabler[down_field] = previous_down
        enabler[lift_field] = previous_lift
        enabler.mouse_focus = previous_mouse_focus
        enabler.tracking_on = previous_tracking_on
        error(first, 0)
    end
    return first, second, third
end

return M
