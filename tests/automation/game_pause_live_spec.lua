-- Live contracts for mount-independent game pause state commands.

describe('game pause state', function()
    local original_pause_state

    setup(function()
        original_pause_state = ds.isGamePaused()
    end)

    it('01 sets the requested pause state', function()
        local requested = not original_pause_state

        assert.equals(requested, ds.setGamePaused(requested))
        assert.equals(requested, ds.isGamePaused())
        assert.is_true(
            ds.current_run().mount_cleanup_probe().game_pause_state_active)
    end)

    it('02 restores the inherited pause state after the example', function()
        assert.equals(original_pause_state, ds.isGamePaused())
        assert.is_false(
            ds.current_run().mount_cleanup_probe().game_pause_state_active)
    end)
end)
