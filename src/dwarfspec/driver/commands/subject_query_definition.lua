-- Verified definitions for subject-only read queries.

local CommandKind = require('dwarfspec.protocol.enums.command_kinds')
local ReadOnlyDefinition = require(
    'dwarfspec.driver.command.read_only_definition')
local SubjectTokens = require('dwarfspec.driver.command.subject_tokens')

---@class dwarfspec.SubjectQueryDefinitions
---@field private _operations table<string, function>
---@field private _subjects dwarfspec.CommandSubjectTokens
local SubjectQueries = {}
SubjectQueries.__index = SubjectQueries

---Creates the subject-query definition owner.
---@param operations table<string, function>
---@return dwarfspec.SubjectQueryDefinitions
function SubjectQueries.new(operations)
    assert(type(operations) == 'table',
        'subject queries require operations')
    for _, name in ipairs({'getFocusList', 'raw'}) do
        assert(type(operations[name]) == 'function',
            'subject queries require ' .. name)
    end
    return setmetatable({_operations=operations,
        _subjects=SubjectTokens.new()}, SubjectQueries)
end

---Creates one subject query definition.
---@param name string
---@return table
function SubjectQueries:_definition(name)
    return ReadOnlyDefinition.new({name='subject.' .. name,
        kind=CommandKind.QUERY,
        normalize=function(arguments)
            return {subject_token=self._subjects:retain(arguments.subject)}
        end,
        preflight=function(_, request)
            local subject = self._subjects:resolve(request.subject_token)
            return self._operations.raw(subject)
        end,
        execute=function(_, request)
            local subject = self._subjects:resolve(request.subject_token)
            return self._operations[name](subject)
        end}):definition()
end

---Creates all subject-only query definitions.
---@return table[]
function SubjectQueries:definitions()
    return {self:_definition('getFocusList'), self:_definition('raw')}
end

---Registers subject-only query definitions and returns their invokers.
---@param command_runner dwarfspec.CommandRunner
---@param operations table<string, function>
---@return table<string, function>
function SubjectQueries.bind(command_runner, operations)
    local owner = SubjectQueries.new(operations)
    for _, definition in ipairs(owner:definitions()) do
        command_runner:registerBuiltin(definition)
    end
    return {
        ---Returns copied native focus strings for one subject.
        ---@param subject table
        ---@param command_options? table
        ---@return string[]
        getFocusList=function(subject, command_options)
            return command_runner:invoke('subject.getFocusList',
                {subject=subject}, command_options)
        end,
        ---Returns the exact adapted object for one subject.
        ---@param subject table
        ---@param command_options? table
        ---@return table|userdata
        raw=function(subject, command_options)
            return command_runner:invoke('subject.raw',
                {subject=subject}, command_options)
        end,
    }
end

return SubjectQueries
