local SaveGameRuntime = require('dwarfspec.driver.game.save_game_runtime')

describe('save game runtime capability', function()
    it('routes host and transition operations through one run-scoped service', function()
        local calls = {}
        local host = {is_world_loaded=function() return true end,
            read_world_folder=function() return 'save' end}
        local runtime = SaveGameRuntime.new({host=host,
            unloader={unload=function(_, current, requested)
                calls[#calls + 1] = {'unload', current, requested}
            end}, loader={
                reach_save_menu=function(_, directory)
                    calls[#calls + 1] = {'menu', directory}
                    return {world_id=1}
                end,
                select_save_world=function(_, directory, world_id)
                    calls[#calls + 1] = {'world', directory, world_id}
                    return {save_index=2}
                end,
                select_save_and_await_map=function(_, directory, save_index)
                    calls[#calls + 1] = {'save', directory, save_index}
                end,
                verify_loaded=function(_, directory)
                    calls[#calls + 1] = {'verify', directory}
                    return directory
                end}})

        assert.equal(host, runtime:host())
        assert.is_true(runtime:is_world_loaded())
        runtime:unload('old', 'new')
        assert.same({world_id=1}, runtime:reach_save_menu('new'))
        assert.same({save_index=2}, runtime:select_save_world('new', 1))
        runtime:select_save_and_await_map('new', 2)
        assert.equal('new', runtime:verify_loaded('new'))
        assert.same({{'unload', 'old', 'new'}, {'menu', 'new'},
            {'world', 'new', 1}, {'save', 'new', 2}, {'verify', 'new'}}, calls)
    end)
end)
