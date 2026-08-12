-- Verified subject.getFocusList command owner.

local ReadOnlyCommand = require(
    'dwarfspec.driver.builtins.read_only_command')
local SubjectTokens = require('dwarfspec.driver.command.subject_tokens')

---@class dwarfspec.SubjectGetFocusListCommand
local SubjectGetFocusList = {}
SubjectGetFocusList.__index = SubjectGetFocusList

---Creates the subject.getFocusList command owner.
---@param runtime dwarfspec.SubjectQueryRuntime
---@return dwarfspec.SubjectGetFocusListCommand
function SubjectGetFocusList.new(runtime)
    local subjects = SubjectTokens.new()
    return setmetatable({_command=ReadOnlyCommand.new({
        name='subject.getFocusList',
        normalize=function(arguments)
            return {subject_token=subjects:retain(arguments.subject)}
        end,
        preflight=function(_, request)
            return runtime:raw(subjects:resolve(request.subject_token))
        end,
        execute=function(_, request)
            return runtime:get_focus_list(
                subjects:resolve(request.subject_token))
        end})}, SubjectGetFocusList)
end

---Returns the subject.getFocusList binding declaration.
---@return table
function SubjectGetFocusList:binding()
    return {surface='subject', name='getFocusList'}
end

---Returns the immutable subject.getFocusList definition.
---@return dwarfspec.CommandDefinition
function SubjectGetFocusList:definition()
    return self._command:definition()
end

---Adapts the public subject.getFocusList signature.
---@param subject table
---@param command_options? table
---@return table, table|nil
function SubjectGetFocusList:arguments(subject, command_options)
    return {subject=subject}, command_options
end

return SubjectGetFocusList
