-- Focused native qualification for the run-owned turbo-speed switch.

local fixture = require('tests.automation.support.unit_speed_fixture')
local CleanupRegistrationProbe = require(
    'tests.automation.support.cleanup_registration_probe')

describe('native turbo speed lifecycle', function()
    local inherited

    setup(function() inherited = df.global.debug_turbospeed end)

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
        assert.is_true(CleanupRegistrationProbe.new(
            ds.current_run()):has_pending_test_cleanup())
    end)

    it('retains the inherited baseline across repeated toggles', function()
        assert.is_true(ds.setTurboSpeed(true))
        assert.is_false(ds.setTurboSpeed(false))
        assert.is_true(ds.setTurboSpeed(true))
        assert.is_true(df.global.debug_turbospeed)
        assert.is_true(CleanupRegistrationProbe.new(
            ds.current_run()):has_pending_test_cleanup())
    end)

    it('restores the inherited switch after each owner teardown', function()
        assert.equals(inherited, df.global.debug_turbospeed)
        assert.is_false(CleanupRegistrationProbe.new(
            ds.current_run()):has_pending_test_cleanup())
    end)
end)
