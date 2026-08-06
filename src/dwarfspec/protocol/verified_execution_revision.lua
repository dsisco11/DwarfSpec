-- Coordinated successor protocol identity for verified command execution.

---@class dwarfspec.VerifiedExecutionRevision
local Revision = {}
Revision.__index = Revision

Revision.PROTOCOL_VERSION = 3
Revision.SERVICE_SCHEMA = 'dwarfspec.service.v3'
Revision.EVENT_SCHEMA = 'dwarfspec.event.v3'
Revision.RESULT_SCHEMA = 'dwarfspec.result.v3'
Revision.RUN_SCHEMA = 'dwarfspec.run.v3'

-- This revision is declaration-only until the coordinated runtime conversion;
-- existing revision-2 producers must not emit any revision-3 shape early.

---Rejects any mixed client, service, event, or result revision.
---@param client_version integer
---@param service_version integer
---@param event_version integer
---@param result_version integer
---@return integer
function Revision.negotiate(client_version, service_version, event_version,
        result_version)
    local expected = Revision.PROTOCOL_VERSION
    local versions = {
        client=client_version,
        service=service_version,
        event=event_version,
        result=result_version,
    }
    for name, version in pairs(versions) do
        assert(version == expected,
            ('verified execution protocol mismatch: %s=%s expected=%d')
                :format(name, tostring(version), expected))
    end
    return expected
end

return Revision
