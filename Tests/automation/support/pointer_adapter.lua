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
    local original_x = gps.mouse_x
    local original_y = gps.mouse_y
    gps.mouse_x = x
    gps.mouse_y = y
    local ok, first, second, third = xpcall(operation, debug.traceback)
    gps.mouse_x = original_x
    gps.mouse_y = original_y
    if not ok then error(first, 0) end
    return first, second, third
end

return M
