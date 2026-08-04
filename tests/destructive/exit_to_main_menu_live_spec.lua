-- Explicitly selected destructive acceptance for disposable automation saves.

local fixtures = require('tests.support.save_game_fixtures')

describe('exit to main menu destructive transition', function()
    local save_directory

    setup(function()
        if dfhack.isWorldLoaded() then
            save_directory = fixtures.current_directory()
        else
            save_directory = fixtures.smallest_directory()
            assert.equals(save_directory,
                ds.mountSaveGame(save_directory))
        end
    end)

    it('discards the loaded save and confirms the native title main menu',
            function()
        assert.equals(save_directory, ds.exitToMainMenu())
        assert.is_false(dfhack.isWorldLoaded())

        local screen = dfhack.gui.getCurViewscreen()
        assert.is_true(df.viewscreen_titlest:is_instance(screen))
        assert.equals(df.title_mode_type.MAIN_MENU, screen.mode)
        assert.is_nil(ds.exitToMainMenu())
    end)
end)
