-- Cohesive mounted-subject query capability.

---@class dwarfspec.SubjectQueryRuntime
---@field private _get_focus_list function
---@field private _resolve_raw function
local SubjectQueryRuntime = {}
SubjectQueryRuntime.__index = SubjectQueryRuntime

---Creates the subject-query runtime capability.
---@param options table
---@return dwarfspec.SubjectQueryRuntime
function SubjectQueryRuntime.new(options)
    assert(type(options) == 'table',
        'subject-query runtime options are required')
    assert(type(options.get_focus_list) == 'function',
        'subject-query runtime requires get_focus_list')
    assert(type(options.resolve_raw) == 'function',
        'subject-query runtime requires resolve_raw')
    return setmetatable({_get_focus_list=options.get_focus_list,
        _resolve_raw=options.resolve_raw}, SubjectQueryRuntime)
end

---Revalidates and returns a subject's raw adapted value.
---@param subject table
---@return any
function SubjectQueryRuntime:raw(subject)
    return self._resolve_raw(subject)
end

---Returns copied native focus strings for one subject.
---@param subject table
---@return string[]
function SubjectQueryRuntime:get_focus_list(subject)
    return self._get_focus_list(subject)
end

return SubjectQueryRuntime
