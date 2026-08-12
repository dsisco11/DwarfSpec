-- Small definition owner shared by built-in queries and assertions.

local CommandKind = require('dwarfspec.protocol.enums.command_kinds')
local IntrinsicKind = require(
    'dwarfspec.protocol.enums.intrinsic_verification_kinds')
local Outcomes = require('dwarfspec.driver.command.outcomes')
local RetryPolicy = require(
    'dwarfspec.protocol.enums.execution_retry_policies')
local Definition = require('dwarfspec.driver.command.definition')

---@class dwarfspec.ReadOnlyCommandDefinition
---@field private _name string
---@field private _kind string
---@field private _normalize function
---@field private _preflight function
---@field private _execute function
---@field private _observe function|nil
local ReadOnlyDefinition = {}
ReadOnlyDefinition.__index = ReadOnlyDefinition

---Creates one query or assertion definition owner.
---@param values table
---@return dwarfspec.ReadOnlyCommandDefinition
function ReadOnlyDefinition.new(values)
    assert(type(values) == 'table',
        'read-only command definition requires values')
    assert(type(values.name) == 'string' and values.name ~= '',
        'read-only command definition requires a name')
    assert(values.kind == CommandKind.QUERY or
            values.kind == CommandKind.ASSERTION,
        'read-only command definition requires query or assertion kind')
    assert(type(values.normalize) == 'function',
        'read-only command definition requires normalization')
    assert(type(values.execute) == 'function' or
            type(values.observe) == 'function',
        'read-only command definition requires execution or observation')
    return setmetatable({_name=values.name, _kind=values.kind,
        _normalize=values.normalize,
        _preflight=values.preflight or function() return true end,
        _execute=values.execute, _observe=values.observe}, ReadOnlyDefinition)
end

---Creates the immutable runner definition.
---@return table
function ReadOnlyDefinition:definition()
    return Definition.validate({name=self._name, kind=self._kind,
        normalize=self._normalize,
        preflight=function(context, request)
            local readiness = self._preflight(context, request)
            return Outcomes.ready(readiness)
        end,
        execute=function(context, request, readiness)
            if self._observe ~= nil then
                return self._observe(context, request, readiness)
            end
            local result = self._execute(context, request, readiness)
            return Outcomes.ready(result)
        end,
        execution_retry_policy=RetryPolicy.ONCE,
        intrinsic_verification=IntrinsicKind.PRIMARY_OBSERVATION})
end

return ReadOnlyDefinition
