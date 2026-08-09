-- Shared immutable-table primitives for detached framework data.

---@class dwarfspec.Immutable
local Immutable = {}

---Creates a shallow read-only proxy over framework-owned data.
---@param source table
---@param label string
---@return table
function Immutable.read_only(source, label)
    assert(type(source) == 'table', 'immutable source must be a table')
    assert(type(label) == 'string' and label ~= '',
        'immutable label must be a nonempty string')
    return setmetatable({}, {
        __index=source,
        __newindex=function() error(label .. ' is immutable', 2) end,
        __pairs=function() return pairs(source) end,
        __len=function() return #source end,
        __metatable=false,
    })
end

---Creates a recursively detached immutable snapshot.
---@param value any
---@param label string
---@param preserve? fun(value: table): boolean
---@return any
function Immutable.freeze(value, label, preserve)
    assert(type(label) == 'string' and label ~= '',
        'immutable label must be a nonempty string')
    assert(preserve == nil or type(preserve) == 'function',
        'immutable preservation hook must be callable')
    local active = {}

    ---Copies one value while rejecting recursive table cycles.
    ---@param candidate any
    ---@return any
    local function copy(candidate)
        if type(candidate) ~= 'table' then return candidate end
        if preserve and preserve(candidate) then return candidate end
        assert(not active[candidate], label .. ' must be acyclic')
        active[candidate] = true
        local data = {}
        for key, entry in pairs(candidate) do
            data[copy(key)] = copy(entry)
        end
        active[candidate] = nil
        return Immutable.read_only(data, label)
    end

    return copy(value)
end

return Immutable
