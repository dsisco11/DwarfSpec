local CommandKind = require('dwarfspec.protocol.enums.command_kinds')
local Outcomes = require('dwarfspec.driver.command.outcomes')
local ViewPositionDefinition = require(
    'dwarfspec.driver.commands.view_position_definition')
local MapViewRuntime = require('dwarfspec.driver.game.map_view_runtime')
local TestRunner = dofile(
    'tests/unit/driver/commands/definition_test_support.lua')

---@class dwarfspec.tests.ViewPositionDefinitionDependencies
local Dependencies = {}

---Creates isolated view-position definition dependencies.
---@return table
function Dependencies.new()
    local current = {x=1, y=2, z=3}
    return MapViewRuntime.new({origins={TOP_LEFT='top-left', CENTER='center'},
        dimensions=function()
            return {map_x1=0, map_x2=9, map_y1=0, map_y2=9}
        end,
        read=function() return current.x, current.y, current.z end,
        write=function(x, y, z)
            current = {x=x, y=y, z=z}
            return true
        end})
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

    it('rejects the former loose accessor bundle', function()
        assert.has_error(function()
            ViewPositionDefinition.new({get_position=function() end,
                set_position=function() end, origin_offset=function() end})
        end, 'view-position command runtime requires top_left_origin')
    end)
end)
