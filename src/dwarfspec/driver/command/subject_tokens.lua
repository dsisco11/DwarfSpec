-- Invocation-bounded tokens for live subjects that cannot enter plain requests.

---@class dwarfspec.CommandSubjectTokens
---@field private _subjects table<integer, table>
---@field private _next_token integer
local SubjectTokens = {}
SubjectTokens.__index = SubjectTokens

---Creates an empty weak subject-token registry.
---@return dwarfspec.CommandSubjectTokens
function SubjectTokens.new()
    return setmetatable({_subjects=setmetatable({}, {__mode='v'}),
        _next_token=0}, SubjectTokens)
end

---Retains one live subject behind a plain invocation token.
---@param subject table
---@return integer
function SubjectTokens:retain(subject)
    assert(type(subject) == 'table', 'command subject must be a table')
    self._next_token = self._next_token + 1
    self._subjects[self._next_token] = subject
    return self._next_token
end

---Resolves one retained subject while its invocation still owns it.
---@param token integer
---@return table
function SubjectTokens:resolve(token)
    return assert(self._subjects[token],
        'command subject is no longer available')
end

return SubjectTokens
