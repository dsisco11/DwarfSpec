-- Live coverage for subject invalidation caused by real overlay-registry changes.

local widgets = require('gui.widgets')
local overlay = require('plugins.overlay')

local staged
local original_name
local replacement_name
local original_config_path
local original_config_contents
local original_config_existed

---@class tests.OwnedInvalidationHarness: widgets.Panel
local OwnedInvalidationHarness = defclass(nil, widgets.Panel)
OwnedInvalidationHarness.ATTRS{
    view_id='owned_invalidation_root',
    frame={w=16, h=4},
}

---Reads one complete binary file for exact cleanup comparison.
---@param path string
---@return string
local function read_file(path)
    local file, open_error = io.open(path, 'rb')
    assert(file, open_error)
    local contents = file:read('*a')
    file:close()
    return contents
end

---Captures the exact native viewscreen child chain.
---@return userdata[]
local function screen_stack()
    local result = {}
    local screen = df.global.gview.view
    while screen do
        table.insert(result, screen)
        screen = screen.child
    end
    return result
end

---Captures the pointer values that native input cleanup must restore.
---@return table
local function pointer_state()
    return {
        get_mouse_pos=dfhack.screen.getMousePos,
        get_mouse_pixels=dfhack.screen.getMousePixels,
        mouse_x=df.global.gps.mouse_x,
        mouse_y=df.global.gps.mouse_y,
        precise_mouse_x=df.global.gps.precise_mouse_x,
        precise_mouse_y=df.global.gps.precise_mouse_y,
    }
end

---Asserts exact equality for a flat pointer snapshot.
---@param expected table
---@param actual table
local function assert_pointer_state(expected, actual)
    assert.same(expected, actual)
end

---Asserts that a borrowed mount retained no runtime ownership residue.
---@param cleanup table
local function assert_native_cleanup(cleanup)
    assert.equals(0, cleanup.active_screen_count)
    assert.equals(0, cleanup.tracked_screen_count)
    assert.equals(0, cleanup.owned_screen_count)
    assert.equals(0, cleanup.borrowed_native_screen_count)
    assert.equals(0, cleanup.subject_count)
    assert.is_false(cleanup.pointer_active)
    assert.is_false(cleanup.button_state_active)
    assert.is_false(cleanup.render_observer_active)
end

describe('overlay registry invalidation', function()
    it('rejects owned source options while retaining the mounted component',
            function()
        local original_current = dfhack.gui.getCurViewscreen(true)
        local original_focus = dfhack.gui.getCurFocus(true)
        local original_stack = screen_stack()
        local root = ds.mount(OwnedInvalidationHarness)
        local native_ok, native_failure = pcall(ds.root, {
            source=ds.ESubjectSource.NATIVE,
        })
        local overlay_ok, overlay_failure = pcall(ds.get, 'missing', {
            source=ds.ESubjectSource.OVERLAY,
            overlay='gui/missing',
        })

        assert.is_false(native_ok)
        assert.is_false(overlay_ok)
        assert.matches('component mounts do not accept subject source options',
            native_failure, 1, true)
        assert.matches('component mounts do not accept subject source options',
            overlay_failure, 1, true)
        assert.equals(root:raw(), ds.root():raw())

        ds.unmount()
        ds.wait_frames(2)
        assert.equals(original_current, dfhack.gui.getCurViewscreen(true))
        assert.same(original_focus, dfhack.gui.getCurFocus(true))
        assert.same(original_stack, screen_stack())
        assert_native_cleanup(ds.current_run().mount_cleanup_probe())
    end)

    it('invalidates retained registry subjects without leaving native residue',
            function()
        local run = ds.current_run()
        local native_screen = dfhack.gui.getDFViewscreen(true)
        local original_current = dfhack.gui.getCurViewscreen(true)
        local original_focus = dfhack.gui.getCurFocus(true)
        local original_stack = screen_stack()
        local original_pointer = pointer_state()
        original_config_path = dfhack.getDFPath() .. '/dfhack-config/overlay.json'
        original_config_existed = dfhack.filesystem.isfile(original_config_path)
        original_config_contents = original_config_existed and
            read_file(original_config_path) or nil

        staged = ds.stage_overlay_registration(
            'tests/automation/support/registry_invalidation_overlay_probe.lua',
            'registry_invalidation')
        original_name = 'gui/' .. staged.script_name .. '.original'
        replacement_name = 'gui/' .. staged.script_name .. '.replacement'
        assert.same({original_name, replacement_name}, staged.registered_names)
        assert.is_true(overlay.overlay_command(
            {'enable', original_name, replacement_name}, true))

        local state = overlay.get_state()
        local original_entry = assert(state.db[original_name])
        local original_widget = original_entry.widget
        local replacement_widget = assert(state.db[replacement_name]).widget
        local source = {source=ds.ESubjectSource.OVERLAY, overlay=original_name}

        ds.mountNativeScreen()
        local retained = ds.get('status', source)
        assert.equals(original_widget, ds.root(source):raw())

        local missing_source = {
            source=ds.ESubjectSource.OVERLAY,
            overlay='gui/dwarfspec-missing-registry-entry',
        }
        local missing_ok, missing_failure = pcall(ds.root, missing_source)
        assert.is_false(missing_ok)
        assert.matches('could not find exact registry', missing_failure, 1, true)
        assert.equals(original_widget, state.db[original_name].widget)
        assert.is_true(state.config[original_name].enabled)
        assert.equals(original_current, dfhack.gui.getCurViewscreen(true))
        assert.same(original_focus, dfhack.gui.getCurFocus(true))
        assert.same(original_stack, screen_stack())

        assert.is_true(overlay.overlay_command({'disable', original_name}, true))
        local disabled_ok, disabled_failure = pcall(retained.text, retained)
        local fresh_disabled_ok, fresh_disabled_failure = pcall(ds.get,
            'status', source)
        assert.is_false(disabled_ok)
        assert.is_false(fresh_disabled_ok)
        assert.matches('stale overlay subject requires enabled registry',
            disabled_failure, 1, true)
        assert.matches('overlay subject selection requires enabled registry',
            fresh_disabled_failure, 1, true)
        assert.is_false(state.config[original_name].enabled)
        assert.equals(original_widget, state.db[original_name].widget)
        assert.equals(original_current, dfhack.gui.getCurViewscreen(true))
        assert.same(original_stack, screen_stack())

        assert.is_true(overlay.overlay_command({'enable', original_name}, true))
        local before_replacement = ds.get('status', source)
        original_entry.widget = replacement_widget
        local replaced_ok, replaced_failure = pcall(before_replacement.text,
            before_replacement)
        assert.is_false(replaced_ok)
        assert.matches('stale overlay subject registry', replaced_failure, 1,
            true)
        local current = ds.get('status', source)
        assert.equals(replacement_widget.subviews.status, current:raw())

        original_entry.widget = original_widget
        assert.equals(original_widget, ds.root(source):raw())
        ds.unmount()
        assert.equals(native_screen, dfhack.gui.getDFViewscreen(true))
        assert.equals(original_current, dfhack.gui.getCurViewscreen(true))
        assert.same(original_focus, dfhack.gui.getCurFocus(true))
        assert.same(original_stack, screen_stack())
        assert_pointer_state(original_pointer, pointer_state())
        assert_native_cleanup(run.mount_cleanup_probe())

        ds.mountNativeScreen()
        assert.equals(native_screen.widgets, ds.root():raw())
        ds.unmount()
        assert_native_cleanup(run.mount_cleanup_probe())
    end)

    it('restores staged registry artifacts after invalidation coverage', function()
        assert.is_truthy(staged)
        assert.same({
            complete=true,
            script_removed=true,
            config_restored=true,
            registrations_removed=true,
            failures={},
        }, staged.cleanup_state)
        assert.is_nil(overlay.get_state().db[original_name])
        assert.is_nil(overlay.get_state().db[replacement_name])
        assert.equals(original_config_existed,
            dfhack.filesystem.isfile(original_config_path))
        if original_config_existed then
            assert.equals(original_config_contents, read_file(original_config_path))
        end
    end)
end)
