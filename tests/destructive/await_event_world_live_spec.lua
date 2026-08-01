-- Destructive live acceptance for save-transition state-change events.

local fixtures = require('tests.support.save_game_fixtures')
local command_conformance = require(
    'tests.automation.support.command_conformance')

local save_a
local save_a_size
local save_b
local save_b_size

---Returns the one-based position of a native state in an event trace.
---@param trace integer[]
---@param expected integer
---@return integer
local function trace_position(trace, expected)
    for index, state in ipairs(trace) do
        if state == expected then return index end
    end
    error(('native state-change trace omitted state %s')
        :format(tostring(expected)), 2)
end

---Asserts that the save transition retained no input or mount ownership.
---@return nil
local function assert_transition_released()
    local cleanup = ds.current_run().mount_cleanup_probe()
    assert.is_false(cleanup.pointer_active)
    assert.is_false(cleanup.button_state_active)
    assert.equals(0, cleanup.active_screen_count)
    assert.equals(0, cleanup.owned_screen_count)
    assert.equals(0, cleanup.borrowed_native_screen_count)
end

describe('awaitEvent destructive world transition', function()
    setup(function()
        if dfhack.isWorldLoaded() then
            save_a = fixtures.current_directory()
        else
            save_a, save_a_size = fixtures.smallest_directory()
            assert.equals(save_a, ds.mountSaveGame(save_a))
        end
        save_b, save_b_size =
            fixtures.smallest_alternate_directory(save_a)
        assert.not_equals(save_a, save_b)
        print(('awaitEvent save fixtures: A=%q A_bytes=%s ' ..
            'B=%q B_bytes=%d'):format(
            save_a, tostring(save_a_size or '<already-loaded>'),
            save_b, save_b_size))
    end)

    it('observes native unload and load events through mountSaveGame',
            function()
        local pointer_before = command_conformance.pointer_snapshot()
        local trace = {}
        local listener_key = 'dwarfspec.awaitEvent.worldLive'
        assert.is_nil(dfhack.onStateChange[listener_key])
        dfhack.onStateChange[listener_key] = function(state)
            if state == SC_MAP_UNLOADED or state == SC_WORLD_UNLOADED or
                    state == SC_WORLD_LOADED or state == SC_MAP_LOADED then
                table.insert(trace, state)
            end
        end

        local ok, failure = xpcall(function()
            assert.equals(save_a, ds.getSaveDirectoryName())
            assert.equals(save_b, ds.mountSaveGame(save_b))
            assert.equals(save_b, ds.getSaveDirectoryName())
            assert.is_false(df.viewscreen_loadgamest:is_instance(
                dfhack.gui.getCurViewscreen()))
        end, debug.traceback)
        dfhack.onStateChange[listener_key] = nil
        assert.is_nil(dfhack.onStateChange[listener_key])
        assert.is_true(ok, failure)

        local map_unloaded = trace_position(trace, SC_MAP_UNLOADED)
        local world_unloaded = trace_position(trace, SC_WORLD_UNLOADED)
        local world_loaded = trace_position(trace, SC_WORLD_LOADED)
        local map_loaded = trace_position(trace, SC_MAP_LOADED)
        assert.is_true(map_unloaded < world_unloaded)
        assert.is_true(world_unloaded < world_loaded)
        assert.is_true(world_loaded < map_loaded)
        command_conformance.assert_pointer_restored(
            pointer_before, command_conformance.pointer_snapshot())
        assert_transition_released()
    end)
end)
