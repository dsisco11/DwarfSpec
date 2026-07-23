-- Immutable string enum for persisted invocation result states.

local immutable_enum = require('dwarfspec.immutable_enum')

---@enum DwarfSpecResultState
return immutable_enum.define({
    QUEUED='queued',
    STARTING='starting',
    RUNNING='running',
    CLEANING='cleaning',
    PASSED='passed',
    FAILED='failed',
    ABORTED='aborted',
    CANCELLED='cancelled',
    USAGE_ERROR='usage_error',
    DEPENDENCY_ERROR='dependency_error',
    CONNECTION_ERROR='connection_error',
    REGISTRATION_ERROR='registration_error',
    QUEUE_TIMEOUT='queue_timeout',
    HOST_ERROR='host_error',
    TIMEOUT='timeout',
    INTERRUPTED='interrupted',
    PERSISTENCE_ERROR='persistence_error',
})
