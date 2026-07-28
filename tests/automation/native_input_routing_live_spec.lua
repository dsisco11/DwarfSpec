-- Live regression for native input routing through registered fullscreen UI.

local gui = require('gui')
local overlay = require('plugins.overlay')

local BUTTON_FIELDS = {
    'mouse_focus',
    'tracking_on',
    'mouse_lbut_down',
    'mouse_lbut_lift',
    'mouse_rbut_down',
    'mouse_rbut_lift',
    'mouse_mbut_down',
    'mouse_mbut_lift',
}

local staged
local overlay_name
local overlay_config_path
local overlay_config_existed
local overlay_config_contents
local fixture_probe
local fixture_screen

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
    local stack = {}
    local screen = df.global.gview.view
    local seen = {}
    while screen do
        assert(not seen[screen], 'native screen stack contains a cycle')
        assert(#stack < 64, 'native screen stack exceeds acceptance limit')
        seen[screen] = true
        table.insert(stack, screen)
        screen = screen.child
    end
    return stack
end

---Captures every pointer and physical-button field DwarfSpec can modify.
---@return table
local function pointer_state()
    local state = {
        get_mouse_pos=dfhack.screen.getMousePos,
        get_mouse_pixels=dfhack.screen.getMousePixels,
        mouse_x=df.global.gps.mouse_x,
        mouse_y=df.global.gps.mouse_y,
        precise_mouse_x=df.global.gps.precise_mouse_x,
        precise_mouse_y=df.global.gps.precise_mouse_y,
    }
    for _, field in ipairs(BUTTON_FIELDS) do
        state[field] = df.global.enabler[field]
    end
    return state
end

---Returns whether two pointer snapshots match exactly.
---@param expected table
---@param actual table
---@return boolean
local function same_pointer_state(expected, actual)
    for name, value in pairs(expected) do
        if actual[name] ~= value then return false end
    end
    for name, value in pairs(actual) do
        if expected[name] ~= value then return false end
    end
    return true
end

---Finds one directly addressable child of the borrowed native root.
---@param root userdata
---@return table|nil
local function named_native_child(root)
    for _, child in ipairs(dfhack.gui.getWidgetChildren(root)) do
        local name_ok, name = pcall(function() return child.name end)
        if name_ok and type(name) == 'string' and name ~= '' and
                not name:find('/', 1, true) then
            return {name=name, raw=child}
        end
    end
    return nil
end

---Returns whether an active-key list contains one exact key name.
---@param names string[]
---@param expected string
---@return boolean
local function contains_key(names, expected)
    for _, name in ipairs(names) do
        if name == expected then return true end
    end
    return false
end

---Asserts that a completed native mount retained no runtime ownership.
---@param cleanup table
---@param expected_attachment_count integer
local function assert_mount_released(cleanup, expected_attachment_count)
    assert.equals(0, cleanup.active_screen_count)
    assert.equals(0, cleanup.tracked_screen_count)
    assert.equals(0, cleanup.owned_screen_count)
    assert.equals(0, cleanup.borrowed_native_screen_count)
    assert.equals(expected_attachment_count, cleanup.native_attachment_count)
    assert.equals(0, cleanup.native_screen_dismissal_count)
    assert.equals(0, cleanup.subject_count)
    assert.is_false(cleanup.pointer_active)
    assert.is_false(cleanup.button_state_active)
    assert.is_false(cleanup.render_observer_active)
end

describe('native input routing through a registered fullscreen overlay',
        function()
    after_each(function()
        pcall(ds.unmount)
        if fixture_probe then pcall(fixture_probe.dismiss_screen, fixture_probe) end
        if fixture_screen and fixture_screen:isActive() then
            pcall(fixture_screen.dismiss, fixture_screen)
        end
        fixture_probe = nil
        fixture_screen = nil

        local native_screen = dfhack.gui.getDFViewscreen(true)
        if dfhack.gui.matchFocusString('dwarfmode/Hauling', native_screen) then
            gui.simulateInput(native_screen, 'LEAVESCREEN')
        end
    end)

    it('follows fullscreen show, dismissal, and reshow without remounting',
            function()
        assert.is_true(dfhack.world.isFortressMode(),
            'native input routing requires a loaded fortress')
        local native_screen = dfhack.gui.getDFViewscreen(true)
        assert.is_true(dfhack.gui.matchFocusString(
            'dwarfmode/Default', native_screen),
            'native input routing must start at dwarfmode/Default')
        assert.equals(native_screen, dfhack.gui.getCurViewscreen(true),
            'native input routing requires no pre-existing fullscreen screen')

        local run = ds.current_run()
        run.native_input_routing_events = {}
        overlay_config_path =
            dfhack.getDFPath() .. '/dfhack-config/overlay.json'
        overlay_config_existed =
            dfhack.filesystem.isfile(overlay_config_path)
        overlay_config_contents = overlay_config_existed and
            read_file(overlay_config_path) or nil
        staged = ds.stage_overlay_registration(
            'tests/automation/support/native_input_fullscreen_probe.lua',
            'native_input_fullscreen')
        overlay_name =
            'gui/' .. staged.script_name .. '.fullscreen_input'
        assert.same({overlay_name}, staged.registered_names)
        assert.is_true(overlay.overlay_command(
            {'enable', overlay_name}, true))

        local state = overlay.get_state()
        fixture_probe = assert(state.db[overlay_name].widget)
        assert.equals(fixture_probe, state.db[overlay_name].widget)
        assert.is_true(state.config[overlay_name].enabled)

        local native_root = native_screen.widgets
        local original_current = dfhack.gui.getCurViewscreen(true)
        local original_focus = dfhack.gui.getCurFocus(true)
        local original_stack = screen_stack()
        local original_pointer = pointer_state()
        local original_pause = df.global.pause_state
        local original_dispatcher = overlay.render_viewscreen_widgets
        local expected_attachment_count =
            run.mount_cleanup_probe().native_attachment_count + 1

        assert.is_true(overlay.overlay_command(
            {'trigger', overlay_name}, true))
        fixture_screen = assert(fixture_probe.active_screen)
        ds.await('registered fullscreen overlay becomes current', function()
            return fixture_screen:isActive() and
                dfhack.gui.getCurViewscreen(true) ==
                    fixture_screen._native and
                fixture_screen.render_count > 0
        end)
        assert.is_true(#screen_stack() > #original_stack)

        local mounted_root = ds.mountNativeScreen()
        assert.equals(native_root, mounted_root:raw())
        assert.equals(native_root, ds.root():raw())
        assert.equals(native_screen, dfhack.gui.getDFViewscreen(true))
        assert.equals(fixture_screen._native,
            dfhack.gui.getCurViewscreen(true))

        local direct_child = assert(named_native_child(native_root),
            'borrowed native root has no stable named child')
        local retained = ds.get(direct_child.name)
        assert.equals(direct_child.raw, retained:raw())

        fixture_probe:set_consume(true)
        local keyboard_count = fixture_screen.keyboard_count
        ds.input('D_HAULING')
        assert.equals(keyboard_count + 1,
            fixture_screen.keyboard_count)
        assert.is_true(contains_key(
            fixture_screen.last_keys, 'D_HAULING'))
        assert.is_true(dfhack.gui.matchFocusString(
            'dwarfmode/Default', native_screen),
            'consumed input must not be replayed to the base DF screen')

        local target = fixture_screen.subviews.target
        local body = assert(target.frame_body,
            'fullscreen input target has no rendered bounds')
        local target_x = math.floor((body.x1 + body.x2) / 2)
        local target_y = math.floor((body.y1 + body.y2) / 2)
        ds.move_pointer(target_x, target_y)
        local pointer_x, pointer_y = dfhack.screen.getMousePos()
        assert.is_true(pointer_x >= body.x1 and pointer_x <= body.x2 and
            pointer_y >= body.y1 and pointer_y <= body.y2,
            'real pointer must lie over the rendered fullscreen target')
        local mouse_count = fixture_screen.mouse_count
        ds.mouseInput(ds.EMouseButton.LEFT)
        assert.equals(mouse_count + 1, fixture_screen.mouse_count)
        assert.is_true(contains_key(fixture_screen.last_keys, '_MOUSE_L'))
        assert.is_true(dfhack.gui.matchFocusString(
            'dwarfmode/Default', native_screen))

        fixture_probe:set_consume(false)
        local pass_count =
            run.native_input_routing_events.passed_to_parent or 0
        ds.input('D_HAULING')
        ds.await('unconsumed input reaches the backing DF screen', function()
            return dfhack.gui.matchFocusString(
                'dwarfmode/Hauling', native_screen)
        end)
        assert.equals(pass_count + 1,
            run.native_input_routing_events.passed_to_parent)
        assert.is_true(fixture_screen:isActive())
        assert.equals(fixture_screen._native,
            dfhack.gui.getCurViewscreen(true))
        ds.input('LEAVESCREEN')
        ds.await('backing DF screen returns to default', function()
            return dfhack.gui.matchFocusString(
                'dwarfmode/Default', native_screen)
        end)
        assert.is_true(fixture_screen:isActive())
        assert.equals(direct_child.raw, retained:raw())

        local first_screen = fixture_screen
        assert.is_true(fixture_probe:dismiss_screen())
        ds.await('first fullscreen overlay dismisses', function()
            return not first_screen:isActive() and
                first_screen._native == nil
        end)
        assert.equals(direct_child.raw, retained:raw())

        ds.input('D_HAULING')
        ds.await('newly current base screen receives input', function()
            return dfhack.gui.matchFocusString(
                'dwarfmode/Hauling', native_screen)
        end)
        ds.input('LEAVESCREEN')
        ds.await('base screen closes the reversible panel', function()
            return dfhack.gui.matchFocusString(
                'dwarfmode/Default', native_screen)
        end)

        assert.is_true(overlay.overlay_command(
            {'trigger', overlay_name}, true))
        fixture_screen = assert(fixture_probe.active_screen)
        assert.not_equals(first_screen, fixture_screen)
        ds.await('registered fullscreen overlay reshows', function()
            return fixture_screen:isActive() and
                dfhack.gui.getCurViewscreen(true) ==
                    fixture_screen._native and
                fixture_screen.render_count > 0
        end)
        assert.equals(direct_child.raw, retained:raw())
        fixture_probe:set_consume(true)
        ds.input('D_HAULING')
        assert.is_true(contains_key(
            fixture_screen.last_keys, 'D_HAULING'))
        assert.is_true(dfhack.gui.matchFocusString(
            'dwarfmode/Default', native_screen))

        local active_screen = fixture_screen
        ds.unmount()
        local cleanup = run.mount_cleanup_probe()
        assert.is_true(active_screen:isActive(),
            'native unmount must not dismiss the current fullscreen screen')
        assert.equals(active_screen._native,
            dfhack.gui.getCurViewscreen(true))
        assert.equals(native_screen, dfhack.gui.getDFViewscreen(true))
        assert.equals(original_dispatcher,
            overlay.render_viewscreen_widgets)
        assert.equals(fixture_probe,
            overlay.get_state().db[overlay_name].widget)
        assert.is_true(overlay.get_state().config[overlay_name].enabled)
        assert.is_true(same_pointer_state(
            original_pointer, pointer_state()))
        assert_mount_released(cleanup, expected_attachment_count)

        assert.is_true(fixture_probe:dismiss_screen())
        ds.await('independent fullscreen cleanup restores the stack', function()
            return not active_screen:isActive() and
                active_screen._native == nil and
                dfhack.gui.getCurViewscreen(true) == original_current
        end)
        fixture_screen = nil
        assert.same(original_focus, dfhack.gui.getCurFocus(true))
        assert.same(original_stack, screen_stack())
        assert.equals(original_pause, df.global.pause_state)
        assert.is_true(same_pointer_state(
            original_pointer, pointer_state()))
        assert.equals(2, run.native_input_routing_events.triggered)
        assert.equals(2, run.native_input_routing_events.dismissed)
        assert.is_true(run.native_input_routing_events.consumed >= 3)
        assert.is_true(
            run.native_input_routing_events.passed_to_parent >= 2)
    end)

    it('verifies independent fullscreen registration restoration', function()
        local run = ds.current_run()
        assert.is_table(staged)
        assert.same({
            complete=true,
            script_removed=true,
            config_restored=true,
            registrations_removed=true,
            failures={},
        }, staged.cleanup_state)
        assert.is_false(dfhack.filesystem.isfile(staged.path))
        assert.is_nil(overlay.get_state().db[overlay_name])
        assert.equals(1, run.native_input_routing_events.enabled)
        assert.equals(1, run.native_input_routing_events.disabled)
        assert.equals(overlay_config_existed,
            dfhack.filesystem.isfile(overlay_config_path))
        if overlay_config_existed then
            assert.equals(overlay_config_contents,
                read_file(overlay_config_path))
        end
    end)
end)
