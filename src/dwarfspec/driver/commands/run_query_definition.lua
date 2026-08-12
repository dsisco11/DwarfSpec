-- Verified definition for the current service-owned run query.

local CommandKind = require('dwarfspec.protocol.enums.command_kinds')
local ReadOnlyDefinition = require(
    'dwarfspec.driver.command.read_only_definition')

---@class dwarfspec.CurrentRunQueryDefinition
local CurrentRunQuery = {}
CurrentRunQuery.__index = CurrentRunQuery

---Creates the current-run query definition owner.
---@return dwarfspec.CurrentRunQueryDefinition
function CurrentRunQuery.new()
    return setmetatable({}, CurrentRunQuery)
end

---Creates the immutable current-run query definition.
---@param query function
---@return table
function CurrentRunQuery:definition(query)
    assert(type(query) == 'function', 'current-run query is required')
    return ReadOnlyDefinition.new({name='current_run',
        kind=CommandKind.QUERY, normalize=function() return {} end,
        execute=function() return query() end}):definition()
end

---Registers and binds the current-run query.
---@param ds table
---@param command_runner dwarfspec.CommandRunner
---@param query function
function CurrentRunQuery.bind(ds, command_runner, query)
    command_runner:registerBuiltin(CurrentRunQuery.new():definition(query))

    ---Returns the exact service-owned active run through the verified runner.
    ---@param command_options? table
    ---@return table
    function ds.current_run(command_options)
        return command_runner:invoke('current_run', {}, command_options)
    end
end

return CurrentRunQuery
