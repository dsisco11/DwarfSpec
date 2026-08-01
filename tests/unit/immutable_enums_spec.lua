-- Unit contracts for immutable closed-set DwarfSpec identifiers.

local immutable_enum = require('dwarfspec.support.immutable_enum')
local EFieldMode =
    require('dwarfspec.driver.subjects.native_game_ui_path').EFieldMode
local EResolutionStage =
    require('dwarfspec.driver.subjects.native_resolution_stages')
local EResolutionFailureKind =
    require('dwarfspec.driver.subjects.native_resolution_failure_kinds')
local ErrorFormat = require('dwarfspec.protocol.configuration.error_formats')
local EventType = require('dwarfspec.protocol.enums.event_types')
local EBaseScreenFocusComparison =
    require('dwarfspec.protocol.diagnostics.base_screen_focus_comparisons')
local OwnerKind = require('dwarfspec.protocol.enums.owner_kinds')
local EMouseButton = require('dwarfspec.driver.input.mouse_buttons')
local EInputState = require('dwarfspec.driver.input.input_states')
local EEvent = require('dwarfspec.driver.state_change_events')
local EPointerSpace = require('dwarfspec.driver.input.pointer_spaces')
local EPointerAnchor = require('dwarfspec.driver.input.pointer_anchors')
local EScreenOrigin = require('dwarfspec.driver.screen_origins')
local ESubjectSource = require('dwarfspec.driver.subjects.subject_sources')
local ResultPolicy = require('dwarfspec.protocol.enums.result_policies')
local ResultState = require('dwarfspec.protocol.enums.result_states')
local RunState = require('dwarfspec.protocol.enums.run_states')
local SchedulerFailureKind =
    require('dwarfspec.protocol.enums.scheduler_failure_kinds')
local TestStatus = require('dwarfspec.protocol.enums.test_statuses')
local RunnerFailureKind = require('dwarfspec.protocol.enums.runner_failure_kinds')

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
    it('exposes stable public values directly', function()
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
        assert.equals('world_loaded', EEvent.WORLD_LOADED)
        assert.equals('world_unloaded', EEvent.WORLD_UNLOADED)
        assert.equals('map_loaded', EEvent.MAP_LOADED)
        assert.equals('map_unloaded', EEvent.MAP_UNLOADED)
        assert.equals('viewscreen_changed', EEvent.VIEWSCREEN_CHANGED)
        assert.equals('paused', EEvent.PAUSED)
        assert.equals('unpaused', EEvent.UNPAUSED)
        assert.equals(1, EPointerSpace.GRID)
        assert.equals(2, EPointerSpace.PIXELS)
        assert.equals(3, EPointerSpace.WORLD_TILE)
        assert.equals('center', EPointerAnchor.CENTER)
        assert.equals('top_left', EPointerAnchor.TOP_LEFT)
        assert.equals('top_right', EPointerAnchor.TOP_RIGHT)
        assert.equals('bottom_left', EPointerAnchor.BOTTOM_LEFT)
        assert.equals('bottom_right', EPointerAnchor.BOTTOM_RIGHT)
        assert.equals(1, EBaseScreenFocusComparison.SAME)
        assert.equals(2, EBaseScreenFocusComparison.CHANGED)
        assert.equals(3, EBaseScreenFocusComparison.UNAVAILABLE)
        assert.equals('top_left', EScreenOrigin.TOP_LEFT)
        assert.equals('top', EScreenOrigin.TOP)
        assert.equals('top_right', EScreenOrigin.TOP_RIGHT)
        assert.equals('left', EScreenOrigin.LEFT)
        assert.equals('center', EScreenOrigin.CENTER)
        assert.equals('right', EScreenOrigin.RIGHT)
        assert.equals('bottom_left', EScreenOrigin.BOTTOM_LEFT)
        assert.equals('bottom', EScreenOrigin.BOTTOM)
        assert.equals('bottom_right', EScreenOrigin.BOTTOM_RIGHT)
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
        assert_immutable(EBaseScreenFocusComparison, 'CHANGED')
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
        assert_immutable(EBaseScreenFocusComparison, 'SAME')
        assert_immutable(ErrorFormat, 'MSBUILD')
        assert_immutable(OwnerKind, 'EXTERNAL')
        assert_immutable(EMouseButton, 'LEFT')
        assert_immutable(EInputState, 'CLICK')
        assert_immutable(EEvent, 'WORLD_LOADED')
        assert_immutable(EPointerSpace, 'GRID')
        assert_immutable(EPointerAnchor, 'CENTER')
        assert_immutable(EScreenOrigin, 'CENTER')
        assert_immutable(ESubjectSource, 'NATIVE')
        assert_immutable(RunState, 'QUEUED')
        assert_immutable(ResultState, 'FAILED')
        assert_immutable(TestStatus, 'SUCCESS')
        assert_immutable(ResultPolicy, 'FILE')
        assert_immutable(SchedulerFailureKind, 'PROJECT_BUSY')
        assert_immutable(RunnerFailureKind, 'HOST')
    end)
end)
