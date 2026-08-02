-- Bounded opaque labels for diagnostic identities.

local M = {}

local identity_ids = setmetatable({}, {__mode='k'})
local next_identity_id = 0

---Returns a bounded label without serializing compound values.
---@param value any
---@return string
function M.of(value)
    if value == nil then return '<nil>' end
    local value_type = type(value)
    if value_type == 'string' or value_type == 'number' or
            value_type == 'boolean' then
        local label = tostring(value)
        if #label > 80 then label = label:sub(1, 77) .. '...' end
        return value_type .. ':' .. label
    end
    local identity = identity_ids[value]
    if not identity then
        next_identity_id = next_identity_id + 1
        identity = value_type .. '#' .. next_identity_id
        identity_ids[value] = identity
    end
    return identity
end

return M
