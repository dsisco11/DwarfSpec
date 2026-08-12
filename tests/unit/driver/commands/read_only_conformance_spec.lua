local CommandKind = require('dwarfspec.protocol.enums.command_kinds')
local Harness = dofile('tests/unit/driver/command/engine_harness.lua')
local MapViewRuntime = require('dwarfspec.driver.game.map_view_runtime')
local Builtins = {}
for _, name in ipairs({'wait_frames', 'wait_ticks', 'await', 'await_event',
        'is_game_paused', 'get_game_speed', 'get_tick', 'get_time',
        'get_save_directory_name', 'has_focus', 'current_run', 'root', 'get',
        'inspect', 'capture_view_tree', 'capture_screen', 'search',
        'get_view_pos', 'subject_get_focus_list', 'subject_raw'}) do
    Builtins[name] = require('dwarfspec.driver.builtins.' .. name)
end
local SearchRuntime = require('dwarfspec.driver.commands.search_runtime')
local TestRunner = dofile(
    'tests/unit/driver/commands/definition_test_support.lua')

---@class dwarfspec.tests.ReadOnlyConformanceMatrix
local Matrix = {}

---Collects every concrete read-only built-in definition.
---@return table[]
function Matrix.definitions()
    local wait = {wait_frames=function(_, count) return count end,
        wait_ticks=function(_, count) return count end,
        wait_event=function(_, event) return {event=event} end,
        wait_until=function(_, _, query) return query() end}
    local game = {is_game_paused=function() return false end,
        get_game_speed=function() return 100 end,
        get_tick=function() return 1 end, get_time=function() return 2 end,
        get_save_directory_name=function() return 'region1' end,
        has_focus=function() return true end}
    local mount = {preflight=function() return true end,
        root=function() return {} end, get=function() return {} end,
        inspect=function() return {} end,
        capture_view_tree=function() return {} end}
    local definitions = {}
    for _, owner in ipairs({
            Builtins.wait_frames.new(wait), Builtins.wait_ticks.new(wait),
            Builtins.await.new(wait), Builtins.await_event.new(wait),
            Builtins.is_game_paused.new(game),
            Builtins.get_game_speed.new(game), Builtins.get_tick.new(game),
            Builtins.get_time.new(game),
            Builtins.get_save_directory_name.new(game),
            Builtins.has_focus.new(game),
            Builtins.current_run.new({current_run=function()
                return {run_id='run'}
            end}), Builtins.root.new(mount), Builtins.get.new(mount),
            Builtins.inspect.new(mount), Builtins.capture_view_tree.new(mount),
            Builtins.capture_screen.new({capture_screen=function()
                return {}
            end})}) do
        definitions[#definitions + 1] = owner:definition()
    end
    local search_mount = {category='native',
        interaction_target={assert_current=function() end}}
    local search_runtime = SearchRuntime.new({mount_context={subject_mounts={},
        require_current=function() return search_mount end,
        resolve_subject=function(_, subject) return subject end},
        matcher=function() return nil end})
    definitions[#definitions + 1] =
        Builtins.search.new(search_runtime):definition()
    local map_runtime = MapViewRuntime.new({origins={TOP_LEFT='top-left',
        CENTER='center'}, dimensions=function()
            return {map_x1=0, map_x2=9, map_y1=0, map_y2=9}
        end, read=function() return 1, 2, 3 end,
        write=function() return true end})
    definitions[#definitions + 1] =
        Builtins.get_view_pos.new(map_runtime):definition()
    local subject = {get_focus_list=function() return {} end,
        raw=function(_, value) return value end}
    definitions[#definitions + 1] =
        Builtins.subject_get_focus_list.new(subject):definition()
    definitions[#definitions + 1] =
        Builtins.subject_raw.new(subject):definition()
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
        local wait_definition = Builtins.wait_frames.new({
            wait_frames=function()
                wait_calls = wait_calls + 1
                if wait_calls == 1 then
                    return Outcomes.pending('wait is armed', {armed=true})
                end
                return Outcomes.fatal('wait failed', {armed=true})
            end,
        }):definition()
        local wait_frames = wait_definition
        local request = wait_frames.normalize({count=1})
        local context = {remaining_ms=function() return 10 end}
        assert.equals('pending', wait_frames.execute(context, request).kind)
        assert.equals('fatal', wait_frames.execute(context, request).kind)
        assert.equals(2, wait_calls)

        local captures, generation = {}, 0
        local capture = Builtins.capture_screen.new({
            capture_screen=function(_, name)
            generation = generation + 1
            captures[name] = {generation=generation}
            return captures[name]
        end}):definition()
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
