-- Focused native qualification for the run-owned turbo-speed switch.

local fixture = require('tests.automation.support.unit_speed_fixture')

describe('native turbo speed lifecycle', function()
    before_each(function()
        fixture.assert_controlled_world()
        assert.is_boolean(df.global.debug_turbospeed)
    end)

    it('sets the global switch without changing pause, TPS, or tick', function()
        local paused = ds.isGamePaused()
        local tps = ds.getGameSpeed()
        local tick = ds.getTick()
        local requested = true

        assert.equals(requested, ds.setTurboSpeed(requested))
        assert.equals(requested, df.global.debug_turbospeed)
        assert.equals(paused, ds.isGamePaused())
        assert.equals(tps, ds.getGameSpeed())
        assert.equals(tick, ds.getTick())
        assert.is_true(
            ds.current_run().mount_cleanup_probe().turbo_speed_active)
    end)

    it('retains the inherited baseline across repeated toggles', function()
        assert.is_true(ds.setTurboSpeed(true))
        assert.is_false(ds.setTurboSpeed(false))
        assert.is_true(ds.setTurboSpeed(true))
        assert.is_true(df.global.debug_turbospeed)
        assert.is_true(
            ds.current_run().mount_cleanup_probe().turbo_speed_active)
    end)
end)
