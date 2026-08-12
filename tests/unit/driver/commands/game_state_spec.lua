local command = require('dwarfspec.driver.commands.game_state')

describe('game-state command binding', function()
    it('leaves scalar observations to their verified command owners', function()
        local previous_df = _G.df
        _G.df = {global={enabler={fps=100}}}
        local ds = {}
        command.bind(ds, {context={get_game_enabler=function() return df.global.enabler end},
            cleanup_module={}, cleanup_registry={}})
        assert.is_nil(ds.getGameSpeed)
        assert.is_function(ds.setGameSpeed)
        _G.df = previous_df
    end)
end)
