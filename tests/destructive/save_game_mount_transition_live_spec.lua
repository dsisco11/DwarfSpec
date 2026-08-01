-- Explicitly selected destructive acceptance for disposable automation saves.

local fixtures = require('tests.support.save_game_fixtures')

---Asserts that no DwarfSpec cleanup action owns the mounted save state.
---@return nil
local function assert_save_state_is_not_cleanup_owned()
    local cleanup = ds.current_run().mount_cleanup_probe()
    assert.is_false(cleanup.pointer_active)
    assert.is_false(cleanup.button_state_active)
end

describe('save-game mount destructive transition', function()
    local save_a
    local save_a_size
    local save_b
    local save_b_size

    setup(function()
        if dfhack.isWorldLoaded() then
            save_a = fixtures.current_directory()
        else
            save_a, save_a_size = fixtures.smallest_directory()
        end
        save_b, save_b_size =
            fixtures.smallest_alternate_directory(save_a)
        assert.not_equals(save_a, save_b)
        print(('save-game fixtures: A=%q A_bytes=%s B=%q B_bytes=%d')
            :format(save_a, tostring(save_a_size or '<already-loaded>'),
                save_b, save_b_size))
        if not dfhack.isWorldLoaded() then
            assert.equals(save_a, ds.mountSaveGame(save_a))
            assert.equals(save_a, ds.getSaveDirectoryName())
        end
    end)

    it('discards A without saving and loads B', function()
        assert.equals(save_a, ds.getSaveDirectoryName())
        assert.equals(save_b, ds.mountSaveGame(save_b))
        assert.equals(save_b, ds.getSaveDirectoryName())
        assert_save_state_is_not_cleanup_owned()
    end)

    it('keeps B loaded after the example and makes a second B mount a no-op',
            function()
        assert.equals(save_b, ds.getSaveDirectoryName())
        assert.equals(save_b, ds.mountSaveGame(save_b))
        assert.equals(save_b, ds.getSaveDirectoryName())
        assert_save_state_is_not_cleanup_owned()
    end)
end)
