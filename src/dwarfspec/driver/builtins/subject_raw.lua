-- Verified subject.raw command owner.

local ReadOnlyCommand = require(
    'dwarfspec.driver.builtins.read_only_command')
local SubjectTokens = require('dwarfspec.driver.command.subject_tokens')

---@class dwarfspec.SubjectRawCommand
local SubjectRaw = {}
SubjectRaw.__index = SubjectRaw

---Creates the subject.raw command owner.
---@param runtime dwarfspec.SubjectQueryRuntime
---@return dwarfspec.SubjectRawCommand
function SubjectRaw.new(runtime)
    local subjects = SubjectTokens.new()
    return setmetatable({_command=ReadOnlyCommand.new({name='subject.raw',
        normalize=function(arguments)
            return {subject_token=subjects:retain(arguments.subject)}
        end,
        preflight=function(_, request)
            return runtime:raw(subjects:resolve(request.subject_token))
        end,
        execute=function(_, request)
            return runtime:raw(subjects:resolve(request.subject_token))
        end})}, SubjectRaw)
end

---Returns the subject.raw binding declaration.
---@return table
function SubjectRaw:binding() return {surface='subject', name='raw'} end

---Returns the immutable subject.raw definition.
---@return dwarfspec.CommandDefinition
function SubjectRaw:definition() return self._command:definition() end

---Adapts the public subject.raw signature.
---@param subject table
---@param command_options? table
---@return table, table|nil
function SubjectRaw:arguments(subject, command_options)
    return {subject=subject}, command_options
end

return SubjectRaw
