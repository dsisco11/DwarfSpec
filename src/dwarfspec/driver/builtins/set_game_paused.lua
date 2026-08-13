-- Verified setGamePaused command owner.

local BooleanSetter = require(
    'dwarfspec.driver.builtins.boolean_state_setter')

---@class dwarfspec.SetGamePausedCommand
---@field private _definition table
local SetGamePaused = {}
SetGamePaused.__index = SetGamePaused

---Creates the setGamePaused command owner.
---@param runtime dwarfspec.GameStateRuntime
---@return dwarfspec.SetGamePausedCommand
function SetGamePaused.new(runtime)
    local definition = BooleanSetter.new({name='setGamePaused',
        runtime=runtime, read='pause_state', write='set_pause',
        label='game pause'}):build_definition()
    return setmetatable({_definition=definition}, SetGamePaused)
end

---Returns the immutable command definition.
---@return table
function SetGamePaused:definition() return self._definition end

---Adapts the public signature.
---@param paused boolean
---@param command_options? table
---@return table, table|nil
function SetGamePaused:arguments(paused, command_options)
    return {value=paused}, command_options
end

return SetGamePaused
