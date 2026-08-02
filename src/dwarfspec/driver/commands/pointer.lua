-- Public pointer and mouse command bindings.

local M = {}

---Creates pointer command bindings from explicit geometry-aware operations.
---@param commands table
---@return table
function M.new(commands)
    for _, name in ipairs({'move_pointer', 'hover', 'click', 'mouseInput', 'mouseWheel'}) do
        assert(type(commands[name]) == 'function',
            'DwarfSpec pointer command implementation must be a function: ' .. name)
    end
    return {
        move_pointer=commands.move_pointer,
        hover=commands.hover,
        click=commands.click,
        mouseInput=commands.mouseInput,
        mouseWheel=commands.mouseWheel,
    }
end

return M
