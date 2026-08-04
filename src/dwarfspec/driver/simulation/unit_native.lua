-- Narrow native helpers for unit simulation composition.

local M = {}

---Returns whether one unit currently carries a rider.
---@param unit any
---@param dependencies? table
---@return boolean
function M.has_rider(unit, dependencies)
    dependencies = dependencies or {}
    if unit.flags1.ridden == true then return true end
    local get_general_ref = dependencies.get_general_ref or
        dfhack.units.getGeneralRef
    local rider_ref_type = dependencies.rider_ref_type or
        df.general_ref_type.UNIT_RIDER
    return get_general_ref(unit, rider_ref_type) ~= nil
end

---Returns whether one unit currently rides another unit.
---@param unit any
---@param dependencies? table
---@return boolean
function M.is_rider(unit, dependencies)
    dependencies = dependencies or {}
    if unit.flags1.rider == true then return true end
    local relationship = dependencies.rider_mount_relationship or
        df.unit_relationship_type.RiderMount
    return unit.relationship_ids[relationship] ~= -1
end

return M
