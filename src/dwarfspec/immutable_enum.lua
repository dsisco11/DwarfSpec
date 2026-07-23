-- Immutable string enum construction for closed DwarfSpec identifiers.

local M = {}

---Creates an immutable string enum and rejects duplicate values.
---@param values table<string, string>
---@return table<string, string>
function M.define(values)
    local data = {}
    local seen = {}
    for name, value in pairs(values) do
        assert(type(name) == 'string' and type(value) == 'string',
            'Enum names and values must be strings.')
        assert(not seen[value], ('Duplicate enum value: %s'):format(value))
        data[name] = value
        seen[value] = true
    end

    return setmetatable({}, {
        __index=data,
        ---Rejects mutation of the immutable enum.
        __newindex=function()
            error('Enums are immutable.', 2)
        end,
        ---Iterates the immutable enum names and string values.
        ---@return function, table, nil
        __pairs=function()
            return pairs(data)
        end,
        __metatable=false,
    })
end

return M
