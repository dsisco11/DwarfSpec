-- Verified setTurboSpeed command owner.

local BooleanSetter = require(
    'dwarfspec.driver.builtins.boolean_state_setter')

---@class dwarfspec.SetTurboSpeedCommand
---@field private _definition table
local SetTurboSpeed = {}
SetTurboSpeed.__index = SetTurboSpeed

---Creates the setTurboSpeed command owner.
---@param runtime dwarfspec.GameStateRuntime
---@return dwarfspec.SetTurboSpeedCommand
function SetTurboSpeed.new(runtime)
    local definition = BooleanSetter.new({name='setTurboSpeed',
        runtime=runtime, read='turbo_state', write='set_turbo',
        label='native turbo speed'}):build_definition()
    return setmetatable({_definition=definition}, SetTurboSpeed)
end

---Returns the immutable command definition.
---@return table
function SetTurboSpeed:definition() return self._definition end

---Adapts the public signature.
---@param enabled boolean
---@param command_options? table
---@return table, table|nil
function SetTurboSpeed:arguments(enabled, command_options)
    return {value=enabled}, command_options
end

return SetTurboSpeed
