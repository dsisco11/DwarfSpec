-- Live acceptance for a non-owning attachment to the current native screen.

local overlay = require('plugins.overlay')
local command_conformance = require(
    'tests.automation.support.command_conformance')

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

---Returns whether one current pointer snapshot exactly matches another.
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

---Asserts that a completed borrowed mount retained no owned runtime state.
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

---Collects slash-bearing names from the current native widget hierarchy.
---@param root userdata
---@return string[]
local function slash_names(root)
    local names = {}
    local visited = {}

    ---Visits one native widget container within a fixed safety budget.
    ---@param widget userdata
    ---@param remaining integer
    local function visit(widget, remaining)
        if remaining <= 0 or visited[widget] then return end
        visited[widget] = true
        local ok, children = pcall(dfhack.gui.getWidgetChildren, widget)
        if not ok then return end
        for _, child in ipairs(children) do
            local name_ok, name = pcall(function() return child.name end)
            if name_ok and type(name) == 'string' and
                    name:find('/', 1, true) then
                table.insert(names, name)
            end
            visit(child, remaining - 1)
        end
    end

    visit(root, 8)
    table.sort(names)
    return names
end

---Finds one directly addressable native child of the supplied root.
---@param root userdata
---@return table|nil
local function named_native_child(root)
    for index, child in ipairs(dfhack.gui.getWidgetChildren(root)) do
        local name_ok, name = pcall(function() return child.name end)
        if name_ok and type(name) == 'string' and name ~= '' and
                not name:find('/', 1, true) then
            return {name=name, index=index - 1, raw=child}
        end
    end
    return nil
end

describe('non-owning native-screen attachment', function()
    local file_base_screen

    setup(function()
        file_base_screen = dfhack.gui.getDFViewscreen(true)
        assert.equals(
            file_base_screen, dfhack.gui.getCurViewscreen(true),
            'native attachment file requires the base screen to be current')
    end)

    teardown(function()
        local base = assert(file_base_screen)
        assert.equals(base, dfhack.gui.getDFViewscreen(true),
            'native attachment file changed the base-screen identity')
        local current = dfhack.gui.getCurViewscreen(true)
        while current and current ~= base do
            assert.is_true(df.viewscreen:is_instance(current))
            assert.matches('^<viewscreen:', tostring(current))
            current.breakdown_level =
                df.interface_breakdown_types.STOPSCREEN
            current = current.parent
        end
        assert.equals(base, current,
            'native attachment cleanup lost the base-screen ancestor')
        ds.wait_frames(2)
    end)

    after_each(function()
        pcall(ds.unmount)
    end)

    it('proves native and overlay behavior with exact mount cleanup',
            function()
        assert.is_true(dfhack.world.isFortressMode(),
            'native acceptance requires a loaded fortress')
        assert.is_true(dfhack.gui.matchFocusString(
            'dwarfmode/Default', dfhack.gui.getDFViewscreen(true)),
            'native acceptance must start at dwarfmode/Default')
        assert.is_true(ds.hasFocus('dwarfmode/Default'),
            'DwarfSpec must match the current native focus')
        assert.is_false(ds.hasFocus('dwarfmode/Info'),
            'DwarfSpec must reject an inactive native focus')
        assert.equals(df.global.cur_year_tick, ds.getTick())
        assert.is_true(ds.getTime() >= 0)
        assert.equals(df.global.pause_state, ds.isGamePaused())

        local run = ds.current_run()
        run.native_overlay_events = {}
        local staged = ds.stage_overlay_registration(
            'tests/automation/support/native_screen_overlay_probe.lua',
            'native_screen')
        local overlay_name =
            'gui/' .. staged.script_name .. '.native_screen'
        assert.same({overlay_name}, staged.registered_names)
        assert.is_true(overlay.overlay_command(
            {'enable', overlay_name}, true))

        local native_screen = dfhack.gui.getDFViewscreen(true)
        local native_root = native_screen.widgets
        local original_current = dfhack.gui.getCurViewscreen(true)
        local original_focus = dfhack.gui.getCurFocus(true)
        local original_stack = screen_stack()
        local original_pointer = pointer_state()
        local original_dispatcher = overlay.render_viewscreen_widgets
        local expected_attachment_count =
            run.mount_cleanup_probe().native_attachment_count + 1
        local root = ds.mountNativeScreen()
        assert.equals(native_root, root:raw())
        assert.equals(native_root, ds.root():raw())
        assert.equals(native_screen, dfhack.gui.getDFViewscreen(true))
        assert.equals(original_current, dfhack.gui.getCurViewscreen(true))
        assert.same(original_focus, dfhack.gui.getCurFocus(true))
        assert.same(original_stack, screen_stack())
        assert.not_equals(original_dispatcher,
            overlay.render_viewscreen_widgets)
        assert.same(dfhack.gui.getFocusStrings(native_screen),
            root:getFocusList())

        local explicit_native = {source=ds.ESubjectSource.NATIVE}
        local explicit_root = ds.root(explicit_native)
        assert.equals(native_root, explicit_root:raw())

        local native_tree = ds.capture_view_tree('native-widget-tree',
            explicit_native)
        assert.is_table(native_tree)
        assert.is_table(native_tree.children)
        assert.is_true(#native_tree.children > 0)
        assert.is_string(native_tree.native_type)
        command_conformance.assert_bounded_tree(native_tree,
            native_tree.class, 128, 8)

        local window_width, window_height = dfhack.screen.getWindowSize()
        local viewport_ok, viewport_failure = pcall(ds.viewport, 61, 29)
        assert.is_false(viewport_ok)
        assert.matches('viewport is unavailable for a non%-owning ' ..
            'native%-screen mount', viewport_failure)
        assert.same({window_width, window_height},
            {dfhack.screen.getWindowSize()})

        local target = assert(named_native_child(native_root),
            'native root has no named direct child for lookup acceptance')
        local named = ds.get(target.name)
        local numeric = ds.get({target.index})
        assert.equals(named:raw(), numeric:raw())
        assert.equals(target.raw, named:raw())
        assert.equals(dfhack.gui.getWidget(native_root, target.name),
            named:raw())
        assert.equals(target.raw, ds.get(target.name, explicit_native):raw())
        assert.same(dfhack.gui.getFocusStrings(native_screen),
            named:getFocusList())

        local explicit_root_options = {
            source=ds.ESubjectSource.NATIVE,
            native_root=native_root,
        }
        local bypass_root = ds.root(explicit_root_options)
        local bypass_target = ds.get({target.index}, explicit_root_options)
        assert.equals(native_root, bypass_root:raw())
        assert.equals(target.raw, bypass_target:raw())
        assert.is_string(bypass_root:inspect().native_type)

        local named_state = named:inspect()
        assert.is_table(named_state.body)
        assert.is_boolean(named_state.visible)
        assert.is_boolean(named_state.active)
        assert.is_string(named_state.native_type)
        assert.same({}, slash_names(native_root),
            'current dwarfmode widget hierarchy unexpectedly gained a ' ..
                'stable slash-bearing name')

        local source = {
            source=ds.ESubjectSource.OVERLAY,
            overlay=overlay_name,
        }
        local overlay_root = ds.root(source)
        local overlay_button = ds.get('accept', source)
        local overlay_editor = ds.get('editor', source)
        local probe = overlay_root:raw()
        assert.equals(
            overlay.get_state().db[overlay_name].widget, probe)
        assert.is_true(probe.render_count > 0)
        local overlay_tree = ds.capture_view_tree('native-overlay-tree', source)
        assert.is_table(overlay_tree)
        assert.is_table(overlay_tree.children)
        assert.is_true(#overlay_tree.children >= 3)
        command_conformance.assert_bounded_tree(overlay_tree,
            overlay_tree.class, 32, 4)
        local overlay_state = overlay_button:inspect()
        assert.equals('accept', overlay_state.view_id)
        assert.is_true(overlay_state.visible)
        assert.is_true(overlay_state.active)
        assert.is_truthy(overlay_state.body)

        local renders = probe.render_count
        ds.redraw()
        assert.is_true(probe.render_count > renders,
            'top-level redraw must wait for a completed overlay render')
        renders = probe.render_count
        named:redraw()
        assert.is_true(probe.render_count > renders,
            'subject redraw must wait for a completed overlay render')
        renders = probe.render_count
        ds.redraw(nil, {wait=false})
        assert.equals(renders, probe.render_count,
            'wait=false must return before the next render generation')
        ds.await('wait=false redraw completes later', function()
            return probe.render_count > renders
        end)

        overlay_button:hover('center')
        local button_x, button_y = dfhack.screen.getMousePos()
        local button_body = assert(overlay_button:inspect().body)
        assert.is_true(button_x >= button_body.x1 and
            button_x <= button_body.x2 and button_y >= button_body.y1 and
            button_y <= button_body.y2,
            'pointer must be over the rendered overlay button')
        overlay_button:click()
        assert.equals(1, probe.click_count)
        assert.equals('clicks: 1', ds.get('status', source):text())
        ds.mouseInput(ds.EMouseButton.LEFT)
        assert.equals(2, probe.click_count)
        assert.equals('clicks: 2', ds.get('status', source):text())
        assert.is_true(probe.input_count > 0)
        ds.mouseInput(ds.EMouseButton.LEFT, ds.EInputState.DOWN)
        ds.mouseInput(ds.EMouseButton.LEFT, ds.EInputState.UP)
        overlay_editor:click():type('native')
        assert.equals('native', overlay_editor:text())

        ds.unmount()
        local cleanup = run.mount_cleanup_probe()
        assert.equals(original_dispatcher,
            overlay.render_viewscreen_widgets)
        assert.equals(native_screen, dfhack.gui.getDFViewscreen(true))
        assert.equals(original_current, dfhack.gui.getCurViewscreen(true))
        assert.same(original_focus, dfhack.gui.getCurFocus(true))
        assert.same(original_stack, screen_stack())
        assert.is_true(same_pointer_state(
            original_pointer, pointer_state()))
        assert_mount_released(cleanup, expected_attachment_count)

        local state = overlay.get_state()
        assert.is_table(state.db[overlay_name],
            'native unmount must not remove an external overlay')
        assert.is_true(state.config[overlay_name].enabled,
            'native unmount must not disable an external overlay')
    end)

    it('restores a borrowed mount after an injected game-UI lookup failure',
            function()
        assert.is_true(dfhack.gui.matchFocusString(
            'dwarfmode/Default', dfhack.gui.getDFViewscreen(true)),
            'cleanup acceptance must start at dwarfmode/Default')
        local run = ds.current_run()
        local native_screen = dfhack.gui.getDFViewscreen(true)
        local original_current = dfhack.gui.getCurViewscreen(true)
        local original_focus = dfhack.gui.getCurFocus(true)
        local original_stack = screen_stack()
        local original_pointer = pointer_state()
        local original_dispatcher = overlay.render_viewscreen_widgets
        local expected_attachment_count =
            run.mount_cleanup_probe().native_attachment_count + 1

        ds.mountNativeScreen()
        ds.move_pointer(0, 0)
        local lookup_ok, lookup_failure = pcall(ds.get, {
            'info',
            'creatures',
            'Tabs',
            'Residents',
            0,
            'Unit List',
            1,
            'injected-missing-row',
        })
        local unmount_ok, unmount_failure = pcall(ds.unmount)
        local cleanup = run.mount_cleanup_probe()

        assert.is_true(unmount_ok, unmount_failure)
        assert.is_false(lookup_ok)
        assert.matches('injected%-missing%-row', lookup_failure)
        assert.equals(original_dispatcher,
            overlay.render_viewscreen_widgets)
        assert.equals(native_screen, dfhack.gui.getDFViewscreen(true))
        assert.equals(original_current, dfhack.gui.getCurViewscreen(true))
        assert.same(original_focus, dfhack.gui.getCurFocus(true))
        assert.same(original_stack, screen_stack())
        assert.is_true(same_pointer_state(
            original_pointer, pointer_state()))
        assert_mount_released(cleanup, expected_attachment_count)
    end)
end)
