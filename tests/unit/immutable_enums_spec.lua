-- Unit contracts for immutable closed-set DwarfSpec identifiers.

local immutable_enum = require('dwarfspec.immutable_enum')
local EFieldMode =
    require('dwarfspec.native_game_ui_path').EFieldMode
local EResolutionStage =
    require('dwarfspec.native_resolution_stages')
local EResolutionFailureKind =
    require('dwarfspec.native_resolution_failure_kinds')
local ErrorFormat = require('dwarfspec.error_formats')
local EventType = require('dwarfspec.automation.event_types')
local OwnerKind = require('dwarfspec.automation.owner_kinds')
local EMouseButton = require('dwarfspec.mouse_buttons')
local EInputState = require('dwarfspec.input_states')
local EPointerSpace = require('dwarfspec.pointer_spaces')
local ESubjectSource = require('dwarfspec.subject_sources')
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
        assert.equals('msbuild', ErrorFormat.MSBUILD)
        assert.equals('gcc', ErrorFormat.GCC)
        assert.equals('eslint', ErrorFormat.ESLINT)
        assert.equals('left', EMouseButton.LEFT)
        assert.equals('scroll_down', EMouseButton.SCROLL_DOWN)
        assert.equals('click', EInputState.CLICK)
        assert.equals('down', EInputState.DOWN)
        assert.equals('up', EInputState.UP)
        assert.equals('grid', EPointerSpace.GRID)
        assert.equals('pixels', EPointerSpace.PIXELS)
        assert.equals('native', ESubjectSource.NATIVE)
        assert.equals('overlay', ESubjectSource.OVERLAY)
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

    it('exposes immutable numeric enum values', function()
        local observed = {}
        for name, value in pairs(EFieldMode) do observed[name] = value end
        assert.same({
            PRIMITIVE=1,
            STATIC_STRING=2,
            POINTER=3,
            STATIC_ARRAY=4,
            SUBSTRUCT=5,
            CONTAINER=6,
            VECTOR_POINTER=7,
            OBJECT_METHOD=8,
            CLASS_METHOD=9,
        }, observed)
        assert_immutable(EFieldMode, 'SUBSTRUCT')
        assert.equals(
            'structure_traversal',
            EResolutionStage.STRUCTURE_TRAVERSAL)
        assert.equals(
            'retained_subject_reacquisition',
            EResolutionStage.RETAINED_SUBJECT_REACQUISITION)
        assert_immutable(EResolutionStage, 'AMBIGUITY_CHECK')
        assert.equals(
            'non_container_value',
            EResolutionFailureKind.NON_CONTAINER_VALUE)
        assert_immutable(EResolutionFailureKind, 'MISSING_WIDGET')
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
        assert.has_error(function()
            immutable_enum.define_numeric({FIRST=1, SECOND=1})
        end, 'Duplicate enum value: 1')
        assert.has_error(function()
            immutable_enum.define_numeric({VALID='1'})
        end, 'Enum names must be strings and values must be numbers.')
        assert.has_error(function()
            immutable_enum.define_numeric({[1]=1})
        end, 'Enum names must be strings and values must be numbers.')
    end)

    it('rejects namespace mutation for every requested type', function()
        assert_immutable(EventType, 'RUN_QUEUED')
        assert_immutable(ErrorFormat, 'MSBUILD')
        assert_immutable(OwnerKind, 'EXTERNAL')
        assert_immutable(EMouseButton, 'LEFT')
        assert_immutable(EInputState, 'CLICK')
        assert_immutable(EPointerSpace, 'GRID')
        assert_immutable(ESubjectSource, 'NATIVE')
        assert_immutable(RunState, 'QUEUED')
        assert_immutable(ResultState, 'FAILED')
        assert_immutable(TestStatus, 'SUCCESS')
        assert_immutable(ResultPolicy, 'FILE')
        assert_immutable(SchedulerFailureKind, 'PROJECT_BUSY')
        assert_immutable(RunnerFailureKind, 'HOST')
    end)
end)
