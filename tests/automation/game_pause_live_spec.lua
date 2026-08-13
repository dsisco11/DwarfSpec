-- Live contracts for mount-independent game pause state commands.

local CleanupRegistrationProbe = require(
    'tests.automation.support.cleanup_registration_probe')

describe('game pause state', function()
    local original_pause_state

    setup(function()
        original_pause_state = ds.isGamePaused()
    end)

    it('01 sets the requested pause state', function()
        local requested = not original_pause_state

        assert.equals(requested, ds.setGamePaused(requested))
        assert.equals(requested, ds.isGamePaused())
        assert.is_true(CleanupRegistrationProbe.new(
            ds.current_run()):has_pending_test_cleanup())
    end)

    it('02 restores the inherited pause state after the example', function()
        assert.equals(original_pause_state, ds.isGamePaused())
        assert.is_false(CleanupRegistrationProbe.new(
            ds.current_run()):has_pending_test_cleanup())
    end)
end)
