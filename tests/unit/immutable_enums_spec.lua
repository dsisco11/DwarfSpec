-- Unit contracts for immutable closed-set DwarfSpec identifiers.

local immutable_enum = require('dwarfspec.immutable_enum')
local EventType = require('dwarfspec.automation.event_types')
local OwnerKind = require('dwarfspec.automation.owner_kinds')
local ResultPolicy = require('dwarfspec.automation.result_policies')
local ResultState = require('dwarfspec.automation.result_states')
local RunState = require('dwarfspec.automation.run_states')
local SchedulerFailureKind =
    require('dwarfspec.automation.scheduler_failure_kinds')
local TestStatus = require('dwarfspec.automation.test_statuses')
local RunnerFailureKind = require('dwarfspec.runner_failure_kinds')

---Asserts that one enum namespace rejects mutation.
---@param enum table
---@param member_name string
local function assert_immutable(enum, member_name)
    local member = enum[member_name]
    assert.has_error(function()
        enum[member_name] = member
    end, 'Enums are immutable.')
end

describe('immutable DwarfSpec contract enums', function()
    it('exposes stable string values directly', function()
        assert.equals('run.queued', EventType.RUN_QUEUED)
        assert.equals('external', OwnerKind.EXTERNAL)
        assert.equals('queued', RunState.QUEUED)
        assert.equals('dependency_error', ResultState.DEPENDENCY_ERROR)
        assert.equals('success', TestStatus.SUCCESS)
        assert.equals('none', ResultPolicy.NONE)
        assert.equals('project_busy', SchedulerFailureKind.PROJECT_BUSY)
        assert.equals('host', RunnerFailureKind.HOST)
        assert.equals('queue_timeout', RunnerFailureKind.QUEUE_TIMEOUT)
        assert.equals('cancelled', RunnerFailureKind.CANCELLED)
        assert.equals(RunState.QUEUED, ResultState.QUEUED)
    end)

    it('supports ordinary pairs iteration', function()
        local observed = {}
        for name, value in pairs(TestStatus) do observed[name] = value end
        assert.same({
            SUCCESS='success',
            FAILURE='failure',
            ERROR='error',
            PENDING='pending',
        }, observed)
    end)

    it('rejects invalid definitions and duplicate values', function()
        assert.has_error(function()
            immutable_enum.define({FIRST='same', SECOND='same'})
        end, 'Duplicate enum value: same')
        assert.has_error(function()
            immutable_enum.define({VALID=1})
        end, 'Enum names and values must be strings.')
        assert.has_error(function()
            immutable_enum.define({[1]='value'})
        end, 'Enum names and values must be strings.')
    end)

    it('rejects namespace mutation for every requested type', function()
        assert_immutable(EventType, 'RUN_QUEUED')
        assert_immutable(OwnerKind, 'EXTERNAL')
        assert_immutable(RunState, 'QUEUED')
        assert_immutable(ResultState, 'FAILED')
        assert_immutable(TestStatus, 'SUCCESS')
        assert_immutable(ResultPolicy, 'FILE')
        assert_immutable(SchedulerFailureKind, 'PROJECT_BUSY')
        assert_immutable(RunnerFailureKind, 'HOST')
    end)
end)
