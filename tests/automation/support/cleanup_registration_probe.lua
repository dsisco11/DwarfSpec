-- Read-only helper for observing cleanup ownership in live acceptance cases.

---@class dwarfspec.tests.CleanupRegistrationProbe
---@field private _run table
local CleanupRegistrationProbe = {}
CleanupRegistrationProbe.__index = CleanupRegistrationProbe

---Creates a probe for one active run handle.
---@param run table
---@return dwarfspec.tests.CleanupRegistrationProbe
function CleanupRegistrationProbe.new(run)
    assert(type(run) == 'table', 'cleanup probe requires a run handle')
    return setmetatable({_run=run}, CleanupRegistrationProbe)
end

---Returns whether the active test attempt owns pending registered cleanup.
---@return boolean
function CleanupRegistrationProbe:has_pending_test_cleanup()
    local owner = self._run.cleanup_owner_lifecycle:public_owner()
    local pending = self._run.cleanup_registration_service:pending_ids_for(
        owner)
    return next(pending) ~= nil
end

return CleanupRegistrationProbe
