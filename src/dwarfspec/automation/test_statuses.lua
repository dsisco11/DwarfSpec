-- Immutable string enum for Busted test completion statuses.

local immutable_enum = require('dwarfspec.immutable_enum')

---@enum DwarfSpecTestStatus
return immutable_enum.define({
    SUCCESS='success',
    FAILURE='failure',
    ERROR='error',
    PENDING='pending',
})
