-- Shared construction mechanics for one-owner read-only built-ins.

local CommandKind = require('dwarfspec.protocol.enums.command_kinds')
local ReadOnlyDefinition = require(
    'dwarfspec.driver.command.read_only_definition')

---@class dwarfspec.ReadOnlyBuiltinCommand
---@field private _name string
---@field private _normalize function
---@field private _execute function
---@field private _preflight function|nil
local ReadOnlyCommand = {}
ReadOnlyCommand.__index = ReadOnlyCommand

---Creates shared read-only command definition mechanics.
---@param options table
---@return dwarfspec.ReadOnlyBuiltinCommand
function ReadOnlyCommand.new(options)
    assert(type(options) == 'table',
        'read-only built-in command options are required')
    assert(type(options.name) == 'string' and options.name ~= '',
        'read-only built-in command name is required')
    assert(type(options.normalize) == 'function',
        'read-only built-in command normalize callback is required')
    assert(type(options.execute) == 'function',
        'read-only built-in command execute callback is required')
    assert(options.preflight == nil or type(options.preflight) == 'function',
        'read-only built-in command preflight callback must be callable')
    return setmetatable({_name=options.name, _normalize=options.normalize,
        _execute=options.execute, _preflight=options.preflight},
        ReadOnlyCommand)
end

---Creates this command's immutable runner definition.
---@return dwarfspec.CommandDefinition
function ReadOnlyCommand:definition()
    return ReadOnlyDefinition.new({name=self._name, kind=CommandKind.QUERY,
        normalize=self._normalize, preflight=self._preflight,
        execute=self._execute}):definition()
end

return ReadOnlyCommand
