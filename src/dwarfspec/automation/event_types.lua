-- Immutable string enum for structured automation event identifiers.

local immutable_enum = require('dwarfspec.immutable_enum')

---@enum DwarfSpecEventType
return immutable_enum.define({
    RUN_QUEUED='run.queued',
    RUN_ACTIVATED='run.activated',
    RUN_CANCELLED='run.cancelled',
    RUN_STARTED='run.started',
    REPEAT_STARTED='repeat.started',
    REPEAT_FINISHED='repeat.finished',
    TEST_STARTED='test.started',
    TEST_FINISHED='test.finished',
    PROBLEM_RECORDED='problem.recorded',
    COMMAND_STARTED='command.started',
    COMMAND_FINISHED='command.finished',
    DIAGNOSTIC_RECORDED='diagnostic.recorded',
    CLEANUP_STARTED='cleanup.started',
    CLEANUP_FAILED='cleanup.failed',
    CLEANUP_FINISHED='cleanup.finished',
    RUN_ABORTED='run.aborted',
    RUN_FINISHED='run.finished',
    SCHEDULER_BLOCKED='scheduler.blocked',
})
