local GameStateRuntime = require(
    'dwarfspec.driver.runtime.game_state_runtime')

describe('game state runtime capability', function()
    it('reads and applies exact pause, turbo, and speed state', function()
        local enabler = {fps=100, gfps=50, fps_per_gfps=2}
        local df = {global={pause_state=false, debug_turbospeed=false}}
        local runtime = GameStateRuntime.new({df=df, context={
            get_game_enabler=function() return enabler end,
            set_game_speed=function(target, tps, ratio)
                target.fps = tps
                target.fps_per_gfps = ratio
                return true
            end,
        }})

        assert.is_false(runtime:pause_state())
        assert.is_true(runtime:set_pause(true))
        assert.is_true(runtime:turbo_state() == false)
        assert.is_true(runtime:set_turbo(true))
        assert.same({tps=100, graphical_rate=50, ratio=2},
            runtime:speed_state())
        assert.is_true(runtime:set_speed({tps=80, ratio=1.6}))
        assert.same({tps=80, graphical_rate=50, ratio=1.6},
            runtime:speed_state())
    end)

    it('rejects unavailable and malformed native state', function()
        local df = {global={pause_state='no', debug_turbospeed=1}}
        local runtime = GameStateRuntime.new({df=df, context={
            get_game_enabler=function() return nil end,
            set_game_speed=function() return true end,
        }})

        assert.has_error(function() runtime:pause_state() end,
            'DwarfSpec setGamePaused requires a valid df.global.pause_state')
        assert.has_error(function() runtime:turbo_state() end,
            'DwarfSpec setTurboSpeed requires a valid ' ..
                'df.global.debug_turbospeed')
        assert.has_error(function() runtime:speed_state() end,
            'DwarfSpec setGameSpeed requires df.global.enabler')
    end)
end)
