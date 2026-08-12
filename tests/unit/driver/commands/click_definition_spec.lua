local CommandKind = require('dwarfspec.protocol.enums.command_kinds')
local Harness = dofile('tests/unit/driver/command/engine_harness.lua')
local Outcomes = require('dwarfspec.driver.command.outcomes')
local ClickDefinition = require('dwarfspec.driver.builtins.click')
local ClickRuntime = require('dwarfspec.driver.input.click_runtime')
local TestRunner = dofile(
    'tests/unit/driver/commands/definition_test_support.lua')
local BuiltinSupport = dofile(
    'tests/unit/driver/commands/builtin_test_support.lua')

---@class dwarfspec.tests.ClickDefinitionDependencies
local Dependencies = {}

---Creates isolated click-definition dependencies.
---@return table
function Dependencies.new()
    return ClickRuntime.new({resolver={resolve=function(_, subject)
        return {}, subject
    end}, dispatch=function() return 0 end})
end

describe('verified click command definition', function()
    it('owns registration and public action binding', function()
        local runner, ds = BuiltinSupport.register({
            ClickDefinition.new(Dependencies.new())})
        local subject, options = {}, {timeout_ms=10}
        assert.equals('click', ds.click(subject, 'right', options))
        assert.same({'click'}, runner:names())
        local invocation = runner:invocations()[1]
        assert.equals(subject, invocation.arguments.subject)
        assert.equals('right', invocation.arguments.button)
        assert.equals(options, invocation.options)
        assert.equals(CommandKind.ACTION, runner:definition('click').kind)
    end)

    it('qualifies intrinsic and optional caller verification', function()
        local harness = Harness.new({observe_render=function() return true end})
        local definition = ClickDefinition.new(Dependencies.new()):definition()
        harness:register(TestRunner.fixture(definition))
        assert.equals(0, harness:invoke('click', {subject={}}, {
            verify=function(observation)
                return observation.public_result == 0
            end}))
    end)

    it('rejects the former loose callback bundle', function()
        assert.has_error(function()
            ClickDefinition.new({resolve_target=function() end,
                dispatch=function() end})
        end, 'click command runtime requires resolve')
    end)
end)
