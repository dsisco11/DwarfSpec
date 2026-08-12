-- Run-scoped tokens for live values excluded from plain command requests.

---@class dwarfspec.CommandOpaqueTokens
---@field private _values table<integer, any>
---@field private _next_token integer
local OpaqueTokens = {}
OpaqueTokens.__index = OpaqueTokens

---Creates an empty opaque-value token registry.
---@return dwarfspec.CommandOpaqueTokens
function OpaqueTokens.new()
    return setmetatable({_values={}, _next_token=0}, OpaqueTokens)
end

---Retains one nonnil live value behind a plain invocation token.
---@param value any
---@return integer
function OpaqueTokens:retain(value)
    assert(value ~= nil, 'opaque command value is required')
    self._next_token = self._next_token + 1
    self._values[self._next_token] = value
    return self._next_token
end

---Resolves one retained live value.
---@param token integer
---@return any
function OpaqueTokens:resolve(token)
    return assert(self._values[token],
        'opaque command value is no longer available')
end

return OpaqueTokens
