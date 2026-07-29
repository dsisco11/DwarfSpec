-- Live contracts for mount-independent game TPS ownership.

---Returns whether two numbers match within native float precision.
---@param actual number
---@param expected number
---@return boolean
local function ratio_matches(actual, expected)
    local scale = math.max(1, math.abs(expected))
    return math.abs(actual - expected) <= 1e-6 * scale
end

describe('game speed', function()
    local inherited

    setup(function()
        local enabler = df.global.enabler
        inherited = {
            tps=enabler.fps,
            graphical_rate=enabler.gfps,
            speed_ratio=enabler.fps_per_gfps,
            paused=ds.isGamePaused(),
        }
    end)

    it('01 sets the TPS target without changing pause state', function()
        local requested = inherited.tps == 100 and 101 or 100
        local enabler = df.global.enabler

        assert.equals(requested, ds.setGameSpeed(requested))
        assert.equals(requested, enabler.fps)
        assert.is_true(ratio_matches(
            enabler.fps_per_gfps, requested / inherited.graphical_rate))
        assert.equals(inherited.graphical_rate, enabler.gfps)
        assert.equals(inherited.paused, ds.isGamePaused())
        assert.is_true(
            ds.current_run().mount_cleanup_probe().game_speed_active)
    end)

    it('02 restores the inherited speed state after the example', function()
        local enabler = df.global.enabler

        assert.equals(inherited.tps, enabler.fps)
        assert.equals(inherited.graphical_rate, enabler.gfps)
        assert.equals(inherited.speed_ratio, enabler.fps_per_gfps)
        assert.equals(inherited.paused, ds.isGamePaused())
        assert.is_false(
            ds.current_run().mount_cleanup_probe().game_speed_active)
    end)
end)
