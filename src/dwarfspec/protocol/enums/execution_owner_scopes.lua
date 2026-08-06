-- Closed command execution-owner vocabulary.

local immutable_enum = require('dwarfspec.support.immutable_enum')

---@enum dwarfspec.EExecutionOwnerScope
return immutable_enum.define({
    SERVICE_RUN='service_run',
    SUITE_EXECUTION='suite_execution',
    TEST_ATTEMPT='test_attempt',
})

