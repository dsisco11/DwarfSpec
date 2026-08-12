local CommandKind = require('dwarfspec.protocol.enums.command_kinds')
local Harness = dofile('tests/unit/driver/command/engine_harness.lua')
local CaptureDefinition = require(
    'dwarfspec.driver.commands.capture_definition')
local GameQueries = require(
    'dwarfspec.driver.commands.game_query_definition')
local MapViewRuntime = require('dwarfspec.driver.game.map_view_runtime')
local MountQueries = require(
    'dwarfspec.driver.commands.mount_query_definition')
local CurrentRunQuery = require(
    'dwarfspec.driver.commands.run_query_definition')
local SearchDefinition = require(
    'dwarfspec.driver.commands.search_definition')
local SearchRuntime = require('dwarfspec.driver.commands.search_runtime')
local SubjectQueries = require(
    'dwarfspec.driver.commands.subject_query_definition')
local ViewPositionDefinition = require(
    'dwarfspec.driver.commands.view_position_definition')
local WaitDefinitions = require(
    'dwarfspec.driver.commands.wait_definition')
local TestRunner = dofile(
    'tests/unit/driver/commands/definition_test_support.lua')

---@class dwarfspec.tests.ReadOnlyConformanceMatrix
local Matrix = {}

---Collects every concrete read-only built-in definition.
---@return table[]
function Matrix.definitions()
    local definitions = WaitDefinitions.new({
        wait_frames=function(count) return count end,
        wait_ticks=function(count) return count end,
        wait_event=function(event) return {event=event} end,
        wait_until=function(_, query) return query() end,
    }):definitions()
    local game = GameQueries.new({isGamePaused=function() return false end,
        getGameSpeed=function() return 100 end,
        getTick=function() return 1 end, getTime=function() return 2 end,
        getSaveDirectoryName=function() return 'region1' end,
        hasFocus=function() return true end})
    for _, definition in ipairs(game:definitions()) do
        definitions[#definitions + 1] = definition
    end
    definitions[#definitions + 1] = CurrentRunQuery.new():definition(
        function() return {run_id='run'} end)
    local mount = MountQueries.new({preflight=function() return true end,
        root=function() return {} end, get=function() return {} end,
        inspect=function() return {} end,
        capture_view_tree=function() return {} end})
    for _, definition in ipairs(mount:definitions()) do
        definitions[#definitions + 1] = definition
    end
    definitions[#definitions + 1] = CaptureDefinition.new(
        function() return {} end):definition()
    local search_mount = {category='native',
        interaction_target={assert_current=function() end}}
    local search_runtime = SearchRuntime.new({mount_context={subject_mounts={},
        require_current=function() return search_mount end,
        resolve_subject=function(_, subject) return subject end},
        matcher=function() return nil end})
    definitions[#definitions + 1] =
        SearchDefinition.new(search_runtime):definition()
    local map_runtime = MapViewRuntime.new({origins={TOP_LEFT='top-left',
        CENTER='center'}, dimensions=function()
            return {map_x1=0, map_x2=9, map_y1=0, map_y2=9}
        end, read=function() return 1, 2, 3 end,
        write=function() return true end})
    definitions[#definitions + 1] =
        ViewPositionDefinition.new(map_runtime):queryDefinition()
    local subject = SubjectQueries.new({getFocusList=function() return {} end,
        raw=function(value) return value end})
    for _, definition in ipairs(subject:definitions()) do
        definitions[#definitions + 1] = definition
    end
    return definitions
end

describe('read-only command family conformance', function()
    it('contains every inventoried runner definition exactly once', function()
        local names = {}
        for _, definition in ipairs(Matrix.definitions()) do
            assert.is_nil(names[definition.name], definition.name)
            names[definition.name] = true
            assert.is_true(definition.kind == CommandKind.QUERY or
                definition.kind == CommandKind.ASSERTION)
            assert.equals('primary_observation',
                definition.intrinsic_verification)
            assert.equals('once', definition.execution_retry_policy)
            assert.is_nil(definition.cleanup)
        end
        assert.same({'await', 'awaitEvent', 'capture_screen',
            'capture_view_tree', 'current_run', 'get', 'getGameSpeed',
            'getSaveDirectoryName', 'getTick', 'getTime', 'getViewPos',
            'hasFocus', 'inspect', 'isGamePaused', 'root', 'search',
            'subject.getFocusList', 'subject.raw', 'wait_frames',
            'wait_ticks'}, (function()
                local result = {}
                for name in pairs(names) do result[#result + 1] = name end
                table.sort(result)
                return result
            end)())
    end)

    it('qualifies successful nil and exact progress observations', function()
        local by_name = {}
        for _, definition in ipairs(Matrix.definitions()) do
            by_name[definition.name] = definition
        end
        local harness = Harness.new({wait_frames=function(count)
            return count
        end, wait_ticks=function(count) return count end})
        for _, name in ipairs({'search', 'wait_frames', 'wait_ticks'}) do
            harness:register(TestRunner.fixture(by_name[name]))
        end
        assert.is_nil(harness:invoke('search', {query={text='missing'}}))
        assert.equals(2, harness:invoke('wait_frames', {count=2}))
        assert.equals(3, harness:invoke('wait_ticks', {count=3}))
    end)

    it('distinguishes pending waits, fatal assertions, and replaced captures',
            function()
        local Outcomes = require('dwarfspec.driver.command.outcomes')
        local wait_calls = 0
        local wait_definitions = WaitDefinitions.new({
            wait_frames=function()
                wait_calls = wait_calls + 1
                if wait_calls == 1 then
                    return Outcomes.pending('wait is armed', {armed=true})
                end
                return Outcomes.fatal('wait failed', {armed=true})
            end,
            wait_ticks=function(count) return count end,
            wait_event=function(event) return {event=event} end,
            wait_until=function(_, query) return query() end,
        }):definitions()
        local wait_frames
        for _, definition in ipairs(wait_definitions) do
            if definition.name == 'wait_frames' then
                wait_frames = definition
            end
        end
        local request = wait_frames.normalize({count=1})
        local context = {remaining_ms=function() return 10 end}
        assert.equals('pending', wait_frames.execute(context, request).kind)
        assert.equals('fatal', wait_frames.execute(context, request).kind)
        assert.equals(2, wait_calls)

        local captures, generation = {}, 0
        local capture = CaptureDefinition.new(function(name)
            generation = generation + 1
            captures[name] = {generation=generation}
            return captures[name]
        end):definition()
        local harness = Harness.new()
        harness:register(TestRunner.fixture(capture))
        assert.equals(1,
            harness:invoke('capture_screen', {name='same'}).generation)
        assert.equals(2,
            harness:invoke('capture_screen', {name='same'}).generation)
        assert.same({generation=2}, captures.same)
        assert.is_nil(capture.cleanup)
    end)
end)
