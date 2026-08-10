local CommandKind = require('dwarfspec.protocol.enums.command_kinds')
local Outcomes = require('dwarfspec.driver.command.outcomes')
local ViewPositionDefinition = require(
    'dwarfspec.driver.commands.view_position_definition')
local TestRunner = dofile(
    'tests/unit/driver/commands/definition_test_support.lua')

---@class dwarfspec.tests.ViewPositionDefinitionDependencies
local Dependencies = {}

---Creates isolated view-position definition dependencies.
---@return table
function Dependencies.new()
    local current = {x=1, y=2, z=3}
    return {top_left_origin='top-left',
        origin_offset=function() return 0, 0 end,
        get_position=function() return current end,
        set_position=function(x, y, z)
            current = {x=x, y=y, z=z}
            return true
        end}
end

describe('verified view-position command definition', function()
    it('owns registration, binding, and reversible effect receipts', function()
        local runner, ds = TestRunner.new(), {}
        ViewPositionDefinition.bind(ds, runner, Dependencies.new())
        local position, options = {x=4, y=5, z=6}, {timeout_ms=10}
        assert.equals('setViewPos', ds.setViewPos(position, 'center', options))
        assert.same({'setViewPos'}, runner:names())
        local invocation = runner:invocations()[1]
        assert.equals(position, invocation.arguments.position)
        assert.equals('center', invocation.arguments.origin)
        assert.equals(CommandKind.STATE_SETTER,
            runner:definition('setViewPos').kind)

        local definition = runner:definition('setViewPos')
        local result = definition.execute({}, {}, {baseline={x=1, y=2, z=3},
            requested={x=4, y=5, z=6}, raw={x=4, y=5, z=6}})
        assert.same(result.receipt, result.effect_receipt)
        assert.is_function(definition.cleanup.restore)
        assert.is_function(definition.cleanup.verify)
    end)
end)
