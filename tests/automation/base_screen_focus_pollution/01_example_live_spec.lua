-- Live proof for post-example base-screen focus-pollution diagnostics.

local gui = require('gui')
local widgets = require('gui.widgets')
local overlay = require('plugins.overlay')
local fixture = require(
    'tests.automation.support.base_screen_focus_pollution')
fixture.bind(ds, assert)

local PRODUCER_NAME =
    'example base-screen focus pollution 10 warns after a successful ' ..
    'native-attachment producer'
local restore_after_example = false
local input_bridge

---@class tests.FocusPollutionOverlay: overlay.OverlayWidget
local FocusPollutionOverlay = defclass(nil, overlay.OverlayWidget)
FocusPollutionOverlay.ATTRS{
    default_pos={x=1, y=1},
    frame={w=12, h=3},
    full_interface=true,
}

---@class tests.FocusPollutionScreen: gui.ZScreen
local FocusPollutionScreen = defclass(nil, gui.ZScreen)
FocusPollutionScreen.ATTRS{
    focus_path='dwarfspec/focus-pollution-screen',
    initial_pause=false,
}

---@class tests.FocusPollutionInputBridge: gui.ZScreen
local FocusPollutionInputBridge = defclass(nil, gui.ZScreen)
FocusPollutionInputBridge.ATTRS{
    focus_path='dwarfspec/focus-pollution-input-bridge',
    initial_pause=false,
}

---Forwards attached input to the exact captured base-game viewscreen.
---@param keys table
---@return boolean
function FocusPollutionInputBridge:onInput(keys)
    gui.simulateInput(self.target_screen, keys)
    return true
end

describe('example base-screen focus pollution', function()
    setup(function()
        fixture.capture_original()
    end)

    after_each(function()
        if restore_after_example then
            restore_after_example = false
            fixture.restore_original()
        end
    end)

    teardown(function()
        if input_bridge and input_bridge:isActive() then
            input_bridge:dismiss()
            ds.await('focus input bridge is dismissed', function()
                return not input_bridge:isActive()
            end)
        end
        input_bridge = nil
        fixture.restore_original()
    end)

    it('01 leaves unchanged focus without a warning', function()
        assert.same({}, fixture.change_events())
    end)

    it('02 confirms the unchanged example emitted no warning', function()
        assert.same({}, fixture.change_events())
    end)

    it('03 cleans an ordinary widget before comparison', function()
        ds.mount(widgets.Panel{
            view_id='ordinary_focus_cleanup',
            frame={w=12, h=3},
        }, {initial_pause=false})
    end)

    it('04 cleans an overlay widget before comparison', function()
        ds.mount(FocusPollutionOverlay, {
            backing_viewscreen=dfhack.gui.getCurViewscreen(true),
            initial_pause=false,
        })
    end)

    it('05 cleans a complete screen before comparison', function()
        ds.mount(FocusPollutionScreen, {
            backing_viewscreen=dfhack.gui.getCurViewscreen(true),
            initial_pause=false,
        })
    end)

    it('06 cleans a passive native attachment before comparison', function()
        ds.mountNativeScreen()
    end)

    it('07 confirms every explicit mount category emitted no warning',
            function()
        assert.same({}, fixture.change_events())
        local cleanup = ds.current_run().mount_cleanup_probe()
        assert.equals(0, cleanup.active_screen_count)
        assert.equals(0, cleanup.owned_screen_count)
        assert.equals(0, cleanup.borrowed_native_screen_count)
        assert.equals(0, cleanup.subject_count)
    end)

    it('08 allows project after_each to suppress a warning', function()
        restore_after_example = true
        fixture.open_hauling()
    end)

    it('09 confirms project after_each suppressed the warning', function()
        assert.same({}, fixture.change_events())
    end)

    it('10 warns after a successful native-attachment producer', function()
        input_bridge = FocusPollutionInputBridge{}
        input_bridge.target_screen = fixture.state().original_screen
        input_bridge:show()
        assert.is_true(input_bridge:isActive())
        assert.equals(
            input_bridge._native, dfhack.gui.getCurViewscreen(true))
        local root = ds.mountNativeScreen()
        root:input('D_HAULING')
        ds.await('native attachment opens Hauling', function()
            return dfhack.gui.matchFocusString(
                'dwarfmode/Hauling', fixture.state().original_screen)
        end)
    end)

    it('11 observes the producer warning after its success result', function()
        local changes = fixture.change_events()
        assert.equals(1, #changes)
        fixture.assert_focus_change(changes[1], {
            scope='example',
            attribution='test',
            suite_name=fixture.EXAMPLE_SUITE,
            example_name=PRODUCER_NAME,
        })
        local success = fixture.success_event(PRODUCER_NAME)
        assert.is_true(success.sequence < changes[1].sequence,
            'focus warning must follow the producer success result')
    end)

    describe('12 nested context without suite semantics', function()
        it('does not create an independent suite warning', function()
            local suite_changes = fixture.change_events(
                function(content)
                    return content.scope == 'suite'
                end)
            assert.same({}, suite_changes)
        end)
    end)
end)
