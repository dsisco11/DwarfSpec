-- Shared schema validation for tests/dwarfspec/config.lua modules.

local settings_validator = require('dwarfspec.settings')

local M = {}

local RESERVED_COMMANDS = {
    EInputState=true,
    EMouseButton=true,
    EPointerSpace=true,
    EScreenOrigin=true,
    await=true,
    capture_screen=true,
    capture_view_tree=true,
    click=true,
    current_run=true,
    get=true,
    getViewPos=true,
    hover=true,
    input=true,
    inspect=true,
    isGamePaused=true,
    mount=true,
    mouseInput=true,
    move_pointer=true,
    protocol_version=true,
    redraw=true,
    root=true,
    setGamePaused=true,
    setGameSpeed=true,
    setViewPos=true,
    stage_overlay_registration=true,
    type=true,
    unmount=true,
    viewport=true,
    wait_frames=true,
    wait_ticks=true,
}

---Validates one project command map without executing callbacks.
---@param callbacks any
---@param source string
---@return table
function M.validate_commands(callbacks, source)
    if callbacks == nil then return {} end
    assert(type(callbacks) == 'table',
        source .. ': commands must be a table')
    for name, callback in pairs(callbacks) do
        assert(type(name) == 'string' and name:match('^[%a_][%w_]*$'),
            source .. ': invalid command name: ' .. tostring(name))
        assert(type(callback) == 'function',
            source .. ': commands.' .. name .. ' must be a function')
        assert(not RESERVED_COMMANDS[name],
            source .. ': custom command conflicts with ds.' .. name)
    end
    return callbacks
end

---Validates one complete project configuration module value.
---@param value any
---@param source string
---@return table
function M.validate(value, source)
    assert(type(value) == 'table',
        source .. ': module must return a table')
    for key in pairs(value) do
        assert(key == 'settings' or key == 'commands',
            source .. ': unknown module field: ' .. tostring(key))
    end
    return {
        settings=settings_validator.validate(value.settings, source),
        commands=M.validate_commands(value.commands, source),
    }
end

return M
