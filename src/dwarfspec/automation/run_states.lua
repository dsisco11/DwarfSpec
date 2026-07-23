-- Immutable string enum for service-owned run lifecycle states.

local immutable_enum = require('dwarfspec.immutable_enum')

---@enum DwarfSpecRunState
return immutable_enum.define({
    QUEUED='queued',
    STARTING='starting',
    RUNNING='running',
    CLEANING='cleaning',
    PASSED='passed',
    FAILED='failed',
    ABORTED='aborted',
    CANCELLED='cancelled',
})
