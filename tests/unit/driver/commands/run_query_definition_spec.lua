local Harness = dofile('tests/unit/driver/command/engine_harness.lua')
local CurrentRunQuery = require(
    'dwarfspec.driver.builtins.current_run')
local TestRunner = dofile(
    'tests/unit/driver/commands/definition_test_support.lua')

describe('verified current run query definition', function()
    it('preserves exact public run identity', function()
        local run = {}
        local definition = CurrentRunQuery.new({
            current_run=function() return run end}):definition()
        local harness = Harness.new()
        harness:register(TestRunner.fixture(definition))
        assert.equals(run, harness:invoke('current_run'))
    end)

    it('does not reinterpret extra Lua returns as outcome evidence', function()
        local definition = CurrentRunQuery.new({current_run=function()
            return {run_id='run'}, 'not evidence'
        end}):definition()
        local outcome = definition.execute({}, {})
        assert.same({run_id='run'}, outcome.value)
        assert.is_nil(outcome.evidence)
    end)
end)
