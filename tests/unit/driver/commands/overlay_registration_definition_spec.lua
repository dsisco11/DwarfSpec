local CommandKind = require('dwarfspec.protocol.enums.command_kinds')
local Outcomes = require('dwarfspec.driver.command.outcomes')
local OverlayRegistrationDefinition = require(
    'dwarfspec.driver.commands.overlay_registration_definition')
local TestRunner = dofile(
    'tests/unit/driver/commands/definition_test_support.lua')

---@class dwarfspec.tests.OverlayRegistrationDefinitionDependencies
local Dependencies = {}

---Creates isolated overlay-fixture definition dependencies.
---@return table
function Dependencies.new()
    return {transaction={prepare=function() return {claims={}} end,
        stage=function() return {staged=true, path='probe.lua',
            registered_names={}} end,
        bindings=function() return {} end,
        verify=function() return true end,
        restore=function() end,
        verify_absent=function() return true end}}
end

describe('verified overlay-registration command definition', function()
    it('owns registration, binding, claims, and cleanup receipts', function()
        local runner, ds = TestRunner.new(), {}
        OverlayRegistrationDefinition.bind(ds, runner, Dependencies.new())
        local options = {timeout_ms=10}
        assert.equals('stage_overlay_registration',
            ds.stage_overlay_registration('probe.lua', 'probe', options))
        assert.same({'stage_overlay_registration'}, runner:names())
        local invocation = runner:invocations()[1]
        assert.equals('probe.lua', invocation.arguments.source_path)
        assert.equals('probe', invocation.arguments.logical_name)
        assert.equals(CommandKind.FIXTURE,
            runner:definition('stage_overlay_registration').kind)

        local definition = runner:definition('stage_overlay_registration')
        local plan = definition.preflight({}, {})
        assert.same({}, definition.claims({}, {}, plan.value))
        local result = definition.execute({}, {}, plan.value)
        assert.same({staged=true}, result.effect_receipt)
        assert.is_function(definition.cleanup.resources)
        assert.is_function(definition.cleanup.restore)
        assert.is_function(definition.cleanup.verify)
    end)
end)
