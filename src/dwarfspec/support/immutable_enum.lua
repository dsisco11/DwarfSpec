-- Immutable string enum construction for closed DwarfSpec identifiers.

local Immutable = require('dwarfspec.support.immutable')
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

    return Immutable.read_only(data, 'enum namespace')
end

---Creates an immutable numeric enum and rejects duplicate values.
---@param values table<string, number>
---@return table<string, number>
function M.define_numeric(values)
    local data = {}
    local seen = {}
    for name, value in pairs(values) do
        assert(type(name) == 'string' and type(value) == 'number' and
            value == value,
            'Enum names must be strings and values must be numbers.')
        assert(not seen[value], ('Duplicate enum value: %s'):format(value))
        data[name] = value
        seen[value] = true
    end

    return Immutable.read_only(data, 'enum namespace')
end

return M
