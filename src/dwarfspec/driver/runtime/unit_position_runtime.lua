-- Cohesive exactly-once unit-position capability.

---@class dwarfspec.UnitPositionRuntime
---@field private _adapter_provider function
local UnitPositionRuntime = {}
UnitPositionRuntime.__index = UnitPositionRuntime

---Creates the unit-position capability.
---@param adapter table|function
---@return dwarfspec.UnitPositionRuntime
function UnitPositionRuntime.new(adapter)
    assert(type(adapter) == 'table' or type(adapter) == 'function',
        'unit-position runtime requires an adapter')
    local provider = type(adapter) == 'function' and adapter or
        function() return adapter end
    if type(adapter) == 'table' then
        for _, name in ipairs({'prepare', 'apply', 'observe',
                'observe_transition', 'restore_receipt'}) do
            assert(type(adapter[name]) == 'function',
                'unit-position runtime requires adapter ' .. name)
        end
    end
    return setmetatable({_adapter_provider=provider}, UnitPositionRuntime)
end

---Returns the current run-owned adapter.
---@return table
function UnitPositionRuntime:_adapter()
    local adapter = self._adapter_provider()
    assert(type(adapter) == 'table',
        'unit-position adapter provider returned an invalid adapter')
    return adapter
end

---Preflights a stable unit and source/destination occupancy.
---@param unit_id integer
---@param position table
---@return table
function UnitPositionRuntime:prepare(unit_id, position)
    local readiness = self:_adapter():prepare(unit_id, position)
    assert(readiness ~= nil,
        'DwarfSpec could not safely preflight the unit position')
    return readiness
end

---Applies one preflighted move.
---@param readiness table
---@return boolean, table|nil
function UnitPositionRuntime:apply(readiness)
    return self:_adapter():apply(readiness)
end

---Observes current position and occupancy for one stable unit.
---@param unit_id integer
---@return table|nil
function UnitPositionRuntime:observe(unit_id)
    return self:_adapter():observe(unit_id)
end

---Observes the moved unit and both occupancy endpoints.
---@param unit_id integer
---@param receipt table
---@return table|nil
function UnitPositionRuntime:observe_transition(unit_id, receipt)
    return self:_adapter():observe_transition(unit_id, receipt)
end

---Restores one immutable unit-position receipt.
---@param receipt table
function UnitPositionRuntime:restore(receipt)
    return self:_adapter():restore_receipt(receipt)
end

return UnitPositionRuntime
