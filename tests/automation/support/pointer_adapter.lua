-- Reversible virtual interface-pointer adapter for live automation.

local M = {}

---Creates an inactive pointer adapter scoped to one cleanup registry.
---@param cleanup_module table
---@param cleanup_registry table
---@return table
function M.new(cleanup_module, cleanup_registry)
    return {
        cleanup_module=cleanup_module,
        cleanup_registry=cleanup_registry,
        x=nil,
        y=nil,
        original_get_mouse_pos=nil,
        patched_get_mouse_pos=nil,
        cleanup_entry=nil,
        original_button_state=nil,
        button_cleanup_entry=nil,
    }
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
