-- Shared mechanics for one scalar game-query command owner.

local ReadOnlyCommand = require(
    'dwarfspec.driver.builtins.read_only_command')

---@class dwarfspec.ScalarQueryCommand
---@field private _command dwarfspec.ReadOnlyBuiltinCommand
local ScalarQueryCommand = {}
ScalarQueryCommand.__index = ScalarQueryCommand

---Creates one no-argument scalar query owner helper.
---@param name string
---@param operation function
---@return dwarfspec.ScalarQueryCommand
function ScalarQueryCommand.new(name, operation)
    assert(type(operation) == 'function', name .. ' query is required')
    return setmetatable({_command=ReadOnlyCommand.new({name=name,
        normalize=function() return {} end,
        execute=function() return operation() end})}, ScalarQueryCommand)
end

---Builds the scalar query's immutable definition.
---@return dwarfspec.CommandDefinition
function ScalarQueryCommand:build_definition()
    local build = self._command.definition
    return build(self._command)
end

return ScalarQueryCommand
