local CommandKind = require('dwarfspec.protocol.enums.command_kinds')
local SetViewPos = require('dwarfspec.driver.builtins.set_view_pos')
local MapViewRuntime = require('dwarfspec.driver.game.map_view_runtime')
local Support = dofile('tests/unit/driver/commands/builtin_test_support.lua')

---@class dwarfspec.tests.SetViewPosDependencies
local Dependencies = {}

---Creates one isolated mutable map-view runtime.
---@return dwarfspec.MapViewRuntime
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

describe('verified setViewPos command', function()
    it('owns registration, binding, and reversible effect receipts', function()
        local runner, ds = Support.register({SetViewPos.new(
            Dependencies.new())})
        local position, options = {x=4, y=5, z=6}, {timeout_ms=10}
        assert.equals('setViewPos', ds.setViewPos(position, 'center', options))
        local invocation = runner:invocations()[1]
        assert.equals(position, invocation.arguments.position)
        assert.equals('center', invocation.arguments.origin)
        local definition = runner:definition('setViewPos')
        assert.equals(CommandKind.STATE_SETTER, definition.kind)
        local result = definition.execute({}, {}, {baseline={x=1, y=2, z=3},
            requested=position, raw=position})
        assert.same(result.receipt, result.effect_receipt)
        assert.is_function(definition.cleanup.restore)
        assert.is_function(definition.cleanup.verify)
    end)

    it('rejects the former loose accessor bundle', function()
        assert.has_error(function()
            SetViewPos.new({get_position=function() end,
                set_position=function() end, origin_offset=function() end})
        end, 'view-position command runtime requires top_left_origin')
    end)
end)
