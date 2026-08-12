local CommandKind = require('dwarfspec.protocol.enums.command_kinds')
local GetViewPos = require('dwarfspec.driver.builtins.get_view_pos')
local MapViewRuntime = require('dwarfspec.driver.game.map_view_runtime')
local Support = dofile('tests/unit/driver/commands/builtin_test_support.lua')

---@class dwarfspec.tests.GetViewPosDependencies
local Dependencies = {}

---Creates one isolated map-view query runtime.
---@return dwarfspec.MapViewRuntime
function Dependencies.new()
    return MapViewRuntime.new({origins={TOP_LEFT='top-left', CENTER='center'},
        dimensions=function()
            return {map_x1=0, map_x2=9, map_y1=0, map_y2=9}
        end,
        read=function() return 1, 2, 3 end,
        write=function() return true end})
end

describe('verified getViewPos command', function()
    it('owns registration, public arguments, and query policy', function()
        local runner, ds = Support.register({GetViewPos.new(
            Dependencies.new())})
        local options = {timeout_ms=10}
        assert.equals('getViewPos', ds.getViewPos('center', options))
        local invocation = runner:invocations()[1]
        assert.equals('center', invocation.arguments.origin)
        assert.equals(options, invocation.options)
        assert.equals(CommandKind.QUERY,
            runner:definition('getViewPos').kind)
    end)
end)
