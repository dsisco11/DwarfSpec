-- Focused live acceptance for run-scoped native state-change events.

local gui = require('gui')

---@class tests.AwaitEventProbeScreen: gui.ZScreen
local AwaitEventProbeScreen = defclass(nil, gui.ZScreen)
AwaitEventProbeScreen.ATTRS{
    focus_path='dwarfspec/await-event-probe',
    initial_pause=false,
}

local original_pause_state
local original_screen
local probe_screen

---Toggles the native pause state through DFHack's simulated input.
---@return nil
local function toggle_pause()
    local screen = assert(dfhack.gui.getCurViewscreen(true),
        'awaitEvent pause proof requires a current native screen')
    gui.simulateInput(screen, 'D_PAUSE')
end

---Restores the inherited pause state without depending on test success.
---@return nil
local function restore_pause_state()
    if original_pause_state == nil or
            ds.isGamePaused() == original_pause_state then
        return
    end
    local input_ok = pcall(toggle_pause)
    if not input_ok or ds.isGamePaused() ~= original_pause_state then
        df.global.pause_state = original_pause_state
    end
    assert.equals(original_pause_state, ds.isGamePaused())
end

---Dismisses the controlled probe screen and confirms the original screen.
---@return nil
local function restore_screen()
    if probe_screen and probe_screen:isActive() then
        probe_screen:dismiss()
    end
    if original_screen and
            dfhack.gui.getCurViewscreen(true) ~= original_screen then
        ds.await('restore original screen after event proof', function()
            return dfhack.gui.getCurViewscreen(true) == original_screen
        end)
    end
    probe_screen = nil
end

describe('awaitEvent selected native events', function()
    before_each(function()
        original_pause_state = ds.isGamePaused()
        original_screen = dfhack.gui.getCurViewscreen(true)
        probe_screen = nil
    end)

    after_each(function()
        restore_screen()
        restore_pause_state()
    end)

    it('captures paused and unpaused events from simulated input', function()
        local first_event = original_pause_state and
            ds.EEvent.UNPAUSED or ds.EEvent.PAUSED
        local second_event = original_pause_state and
            ds.EEvent.PAUSED or ds.EEvent.UNPAUSED

        local first = ds.awaitEvent(first_event, {
            description='toggle inherited pause state',
            trigger=toggle_pause,
        })
        assert.equals(first_event, first.event)
        assert.equals('state_change', first.source)
        assert.equals(not original_pause_state, first.payload.paused)
        assert.equals(not original_pause_state, ds.isGamePaused())

        local second = ds.awaitEvent(second_event, {
            description='restore inherited pause state',
            trigger=toggle_pause,
        })
        assert.equals(second_event, second.event)
        assert.equals('state_change', second.source)
        assert.equals(original_pause_state, second.payload.paused)
        assert.equals(original_pause_state, ds.isGamePaused())
    end)

    it('captures controlled native screen show and dismissal', function()
        probe_screen = AwaitEventProbeScreen{}
        local shown = ds.awaitEvent(ds.EEvent.VIEWSCREEN_CHANGED, {
            description='show controlled event probe screen',
            trigger=function() probe_screen:show() end,
        })

        assert.equals(ds.EEvent.VIEWSCREEN_CHANGED, shown.event)
        assert.equals('state_change', shown.source)
        assert.matches('dwarfspec/await%-event%-probe$',
            shown.payload.focus)
        assert.is_true(shown.payload.native_screen_type == nil or
            type(shown.payload.native_screen_type) == 'string')
        assert.equals(probe_screen._native,
            dfhack.gui.getCurViewscreen(true))

        local dismissed = ds.awaitEvent(ds.EEvent.VIEWSCREEN_CHANGED, {
            description='dismiss controlled event probe screen',
            trigger=function() probe_screen:dismiss() end,
        })
        assert.equals(ds.EEvent.VIEWSCREEN_CHANGED, dismissed.event)
        assert.equals('state_change', dismissed.source)
        assert.is_false(probe_screen:isActive())
        assert.equals(original_screen, dfhack.gui.getCurViewscreen(true))
    end)
end)
