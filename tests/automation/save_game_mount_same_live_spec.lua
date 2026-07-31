-- Safe live acceptance for mounting the save that is already loaded.

---Asserts that no mount or pointer cleanup was acquired by a same-save mount.
---@return nil
local function assert_no_mount_save_game_cleanup()
    local cleanup = ds.current_run().mount_cleanup_probe()
    assert.is_false(cleanup.pointer_active)
    assert.is_false(cleanup.button_state_active)
end

describe('save-game mount same-save automation', function()
    it('leaves the already loaded disposable save untouched', function()
        local directory = ds.getSaveDirectoryName()
        assert.equals(directory, ds.mountSaveGame(directory))
        assert.equals(directory, ds.getSaveDirectoryName())
        assert_no_mount_save_game_cleanup()
    end)
end)
