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
---@field screen? table
---@field gui? table
---@field gps? table
---@field enabler? table

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
        screen=dependencies.screen,
        gui=dependencies.gui,
        gps=dependencies.gps,
        enabler=dependencies.enabler,
        current_position=nil,
        original_raw_position=nil,
        original_get_mouse_pos=nil,
        original_get_mouse_pixels=nil,
        original_gui_get_mouse_pos=nil,
        patched_get_mouse_pos=nil,
        patched_get_mouse_pixels=nil,
        patched_gui_get_mouse_pos=nil,
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

---Validates and defensively copies one paired pointer position.
---@param position table
---@return DwarfSpecPointerPosition
local function copy_position(position)
    assert(type(position) == 'table',
        'paired pointer position must be a table')
    local copy = {grid={}, pixels={}}
    for _, space in ipairs({'grid', 'pixels'}) do
        assert(type(position[space]) == 'table',
            ('paired pointer position requires %s coordinates'):format(space))
        for _, axis in ipairs({'x', 'y'}) do
            local value = position[space][axis]
            assert(type(value) == 'number' and value % 1 == 0,
                ('paired pointer %s %s coordinate must be an integer')
                    :format(space, axis))
            copy[space][axis] = value
        end
    end
    return copy
end

---Writes both raw coordinate pairs from the active logical position.
---@param adapter table
local function apply_position(adapter)
    local position = assert(adapter.current_position,
        'pointer synchronization requires an active pointer position')
    local gps = assert(adapter.gps,
        'pointer adapter requires an injected gps boundary')
    gps.mouse_x = position.grid.x
    gps.mouse_y = position.grid.y
    gps.precise_mouse_x = position.pixels.x
    gps.precise_mouse_y = position.pixels.y
end

---Runs one restoration operation and records failure without stopping cleanup.
---@param failures string[]
---@param label string
---@param operation function
local function attempt_restoration(failures, label, operation)
    local ok, failure = xpcall(operation, debug.traceback)
    if not ok then
        table.insert(failures,
            ('%s restoration failed: %s'):format(label, tostring(failure)))
    end
end

---Restores one accessor only when the adapter still owns its patch.
---@param container table
---@param field string
---@param patched function|nil
---@param original function|nil
---@param failures string[]
---@param label string
local function restore_accessor(container, field, patched, original, failures,
        label)
    if container[field] ~= patched then
        table.insert(failures, label .. ' changed externally')
        return
    end
    attempt_restoration(failures, label, function()
        container[field] = original
    end)
end

---Restores all pointer state and reports accessor conflicts after best effort.
---@param adapter table
local function restore(adapter)
    if not adapter.current_position then return end
    local failures = {}
    local gps = adapter.gps
    local original = adapter.original_raw_position
    for _, field in ipairs({
            'mouse_x',
            'mouse_y',
            'precise_mouse_x',
            'precise_mouse_y'}) do
        attempt_restoration(failures, 'gps.' .. field, function()
            gps[field] = original[field]
        end)
    end
    restore_accessor(adapter.screen, 'getMousePos',
        adapter.patched_get_mouse_pos,
        adapter.original_get_mouse_pos,
        failures, 'getMousePos')
    restore_accessor(adapter.screen, 'getMousePixels',
        adapter.patched_get_mouse_pixels,
        adapter.original_get_mouse_pixels,
        failures, 'getMousePixels')
    restore_accessor(adapter.gui, 'getMousePos',
        adapter.patched_gui_get_mouse_pos,
        adapter.original_gui_get_mouse_pos,
        failures, 'dfhack.gui.getMousePos')

    adapter.current_position = nil
    adapter.original_raw_position = nil
    adapter.original_get_mouse_pos = nil
    adapter.original_get_mouse_pixels = nil
    adapter.original_gui_get_mouse_pos = nil
    adapter.patched_get_mouse_pos = nil
    adapter.patched_get_mouse_pixels = nil
    adapter.patched_gui_get_mouse_pos = nil
    adapter.cleanup_entry = nil
    if #failures > 0 then
        error('automation pointer restoration conflicts: ' ..
            table.concat(failures, '; '), 0)
    end
end

---Claims pointer ownership once and applies one normalized paired position.
---@param adapter table
---@param position DwarfSpecPointerPosition
function M.set(adapter, position)
    local screen = assert(adapter.screen,
        'pointer adapter requires an injected screen boundary')
    local gui = assert(adapter.gui,
        'pointer adapter requires an injected gui boundary')
    local gps = assert(adapter.gps,
        'pointer adapter requires an injected gps boundary')
    position = copy_position(position)
    if not adapter.current_position then
        adapter.original_raw_position = {
            mouse_x=gps.mouse_x,
            mouse_y=gps.mouse_y,
            precise_mouse_x=gps.precise_mouse_x,
            precise_mouse_y=gps.precise_mouse_y,
        }
        adapter.original_get_mouse_pos = screen.getMousePos
        adapter.original_get_mouse_pixels = screen.getMousePixels
        adapter.original_gui_get_mouse_pos = gui.getMousePos
        assert(type(adapter.original_gui_get_mouse_pos) == 'function',
            'pointer adapter requires gui.getMousePos')
        ---Returns the active logical UI-grid coordinate.
        ---@return integer, integer
        adapter.patched_get_mouse_pos = function()
            apply_position(adapter)
            local current = adapter.current_position.grid
            return current.x, current.y
        end
        ---Returns the active logical screen-pixel coordinate.
        ---@return integer, integer
        adapter.patched_get_mouse_pixels = function()
            apply_position(adapter)
            local current = adapter.current_position.pixels
            return current.x, current.y
        end
        ---Returns the native map coordinate after repairing paired raw state.
        ---@param ... any
        ---@return ...
        adapter.patched_gui_get_mouse_pos = function(...)
            apply_position(adapter)
            return adapter.original_gui_get_mouse_pos(...)
        end
        adapter.current_position = position
        screen.getMousePos = adapter.patched_get_mouse_pos
        screen.getMousePixels = adapter.patched_get_mouse_pixels
        gui.getMousePos = adapter.patched_gui_get_mouse_pos
        adapter.cleanup_entry = adapter.cleanup_module.push(
            adapter.cleanup_registry, 'virtual pointer', function()
                restore(adapter)
            end)
    else
        adapter.current_position = position
    end
    apply_position(adapter)
end

---Returns a defensive copy of the active paired pointer position.
---@param adapter table
---@return DwarfSpecPointerPosition
function M.position(adapter)
    assert(adapter.current_position,
        'mouse input requires a pointer position; call ds.move_pointer() ' ..
        'or subject:hover() first')
    return copy_position(adapter.current_position)
end

---Reapplies both active raw coordinate pairs before native input dispatch.
---@param adapter table
function M.sync(adapter)
    assert(adapter.current_position,
        'mouse input requires a pointer position; call ds.move_pointer() ' ..
        'or subject:hover() first')
    apply_position(adapter)
end

---Returns whether this adapter currently owns a paired pointer position.
---@param adapter table
---@return boolean
function M.is_active(adapter)
    return adapter.current_position ~= nil
end

---Removes the virtual pointer adapter immediately.
---@param adapter table
function M.clear(adapter)
    if not adapter.current_position then return end
    local cleanup_entry = adapter.cleanup_entry
    local ok, failure = xpcall(function()
        restore(adapter)
    end, debug.traceback)
    adapter.cleanup_module.release(adapter.cleanup_registry, cleanup_entry)
    if not ok then error(failure, 0) end
end

---Runs one mouse operation with temporary native focus and tracking flags.
---@param adapter table
---@param operation function
---@return any
function M.with_mouse_focus(adapter, operation)
    local enabler = assert(adapter.enabler,
        'pointer adapter requires an injected enabler boundary')
    local original_mouse_focus = enabler.mouse_focus
    local original_tracking_on = enabler.tracking_on
    enabler.mouse_focus = true
    enabler.tracking_on = 1
    local ok, first, second, third = xpcall(operation, debug.traceback)
    enabler.mouse_focus = original_mouse_focus
    enabler.tracking_on = original_tracking_on
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
    local enabler = assert(adapter.enabler,
        'pointer adapter requires an injected enabler boundary')
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
    local enabler = adapter.enabler
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
