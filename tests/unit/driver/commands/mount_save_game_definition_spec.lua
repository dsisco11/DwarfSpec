local CommandKind = require('dwarfspec.protocol.enums.command_kinds')
local Harness = dofile('tests/unit/driver/command/engine_harness.lua')
local MountSaveGameDefinition = require(
    'dwarfspec.driver.commands.mount_save_game_definition')
local TestRunner = dofile(
    'tests/unit/driver/commands/definition_test_support.lua')

---@class dwarfspec.tests.MountSaveGameDefinitionDependencies
local Dependencies = {}

---Creates isolated save-workflow dependencies and an ordered call log.
---@return table, string[]
function Dependencies.new()
    local calls = {}
    local loaded = false
    local dependencies = {
        workflow={
            validate_directory_name=function(_, value) return value end,
            preflight=function(_, _, requested)
                return {requested_directory=requested,
                    loaded_directory=nil, transition_required=false}
            end,
        },
        host={is_world_loaded=function() return loaded end,
            read_world_folder=function() return nil end},
        unloader={unload=function()
            calls[#calls + 1] = 'unload_current'
        end},
        loader={
            reach_save_menu=function()
                calls[#calls + 1] = 'reach_menu'
                return {world_id=1}
            end,
            select_save_world=function()
                calls[#calls + 1] = 'select_world'
                return {save_index=1}
            end,
            select_save_and_await_map=function()
                calls[#calls + 1] = 'select_save'
                loaded = true
            end,
            verify_loaded=function()
                calls[#calls + 1] = 'verify_loaded'
                return 'save'
            end,
        },
    }
    return dependencies, calls
end

---Returns the workflow step names in declaration order.
---@param definition table
---@return string[]
function Dependencies.step_names(definition)
    local names = {}
    for _, step in ipairs(definition.workflow.steps) do
        names[#names + 1] = step.name
    end
    return names
end

describe('verified mount-save-game command definition', function()
    it('owns registration and public workflow binding', function()
        local dependencies = Dependencies.new()
        local runner, ds = TestRunner.new(), {}
        MountSaveGameDefinition.bind(ds, runner, dependencies)
        local options = {timeout_ms=10}
        assert.equals('mountSaveGame', ds.mountSaveGame('save', options))
        assert.same({'mountSaveGame'}, runner:names())
        assert.equals('save',
            runner:invocations()[1].arguments.directory_name)
        assert.equals(CommandKind.WORKFLOW,
            runner:definition('mountSaveGame').kind)
    end)

    it('runs the exact named sequence with stable step outputs', function()
        local dependencies, calls = Dependencies.new()
        local definition = MountSaveGameDefinition.new(
            dependencies):definition()
        assert.same({'unload_current_save', 'reach_save_menu',
            'select_save_world', 'select_save_game', 'await_save_map',
            'verify_loaded_save'}, Dependencies.step_names(definition))
        local harness = Harness.new()
        harness:register(TestRunner.fixture(definition))
        assert.equals('save', harness:invoke('mountSaveGame',
            {directory_name='save'}))
        assert.same({'reach_menu', 'select_world', 'select_save',
            'verify_loaded'}, calls)
    end)
end)
