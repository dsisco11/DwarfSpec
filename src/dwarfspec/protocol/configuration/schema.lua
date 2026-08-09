-- Shared schema validation for tests/dwarfspec/config.lua modules.

local settings_validator = require('dwarfspec.protocol.configuration.settings')

local M = {}

local RESERVED_COMMANDS = {
    EEvent=true,
    EInputState=true,
    EMouseButton=true,
    EPointerSpace=true,
    EScreenOrigin=true,
    await=true,
    awaitEvent=true,
    capture_screen=true,
    capture_view_tree=true,
    click=true,
    current_run=true,
    exitToMainMenu=true,
    get=true,
    getGameSpeed=true,
    getViewPos=true,
    hover=true,
    input=true,
    inspect=true,
    isGamePaused=true,
    mount=true,
    mountSaveGame=true,
    mouseInput=true,
    mouseWheel=true,
    move_pointer=true,
    protocol_version=true,
    registerCleanup=true,
    redraw=true,
    root=true,
    search=true,
    setGamePaused=true,
    setGameSpeed=true,
    setUnitPos=true,
    setUnitSpeed=true,
    setViewPos=true,
    stage_overlay_registration=true,
    type=true,
    unmount=true,
    viewport=true,
    wait_frames=true,
    wait_ticks=true,
}

---Validates one project command-definition map without importing its driver.
---@param callbacks any
---@param source string
---@return table
function M.validate_commands(callbacks, source)
    if callbacks == nil then return {} end
    assert(type(callbacks) == 'table',
        source .. ': commands must be a table')
    for name, definition in pairs(callbacks) do
        assert(type(name) == 'string' and name:match('^[%a_][%w_]*$'),
            source .. ': invalid command name: ' .. tostring(name))
        assert(not RESERVED_COMMANDS[name],
            source .. ': custom command conflicts with ds.' .. name)
        assert(type(definition) == 'table',
            source .. ': commands.' .. name ..
            ' must be a command definition table; bare callbacks are unsupported')
        assert(definition.name == name,
            source .. ': commands.' .. name ..
            ' definition name must match its map key')
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
