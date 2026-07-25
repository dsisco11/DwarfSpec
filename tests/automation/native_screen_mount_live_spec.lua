-- Live acceptance for a non-owning attachment to the current native screen.

local gui = require('gui')
local guidm = require('gui.dwarfmode')
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

---Copies one array without retaining the caller's mutable table.
---@param values any[]
---@return any[]
local function copy_array(values)
    local copy = {}
    for index, value in ipairs(values) do copy[index] = value end
    return copy
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
        mouse_x=df.global.gps.mouse_x,
        mouse_y=df.global.gps.mouse_y,
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

---Returns whether one screen cell belongs to a native graphics panel.
---@param x integer
---@param y integer
---@return boolean
local function is_native_panel_cell(x, y)
    local tile = dfhack.screen.readTile(x, y)
    return tile and tile.write_to_lower or false
end

---Finds the rendered native Hauling panel using its graphics-backed cells.
---@param sample_y integer
---@return table|nil
local function hauling_panel_bounds(sample_y)
    local map = guidm.getPanelLayout().map
    local best_x1, best_x2
    local run_x1
    for x=map.x1,map.x2 + 1 do
        if x <= map.x2 and is_native_panel_cell(x, sample_y) then
            run_x1 = run_x1 or x
        elseif run_x1 then
            local run_x2 = x - 1
            if not best_x1 or run_x2 - run_x1 > best_x2 - best_x1 then
                best_x1, best_x2 = run_x1, run_x2
            end
            run_x1 = nil
        end
    end
    if not best_x1 then return nil end

    local interior_x = math.min(best_x1 + 1, best_x2)
    local _, screen_height = dfhack.screen.getWindowSize()
    local y1, y2 = sample_y, sample_y
    while y1 > 0 and is_native_panel_cell(interior_x, y1 - 1) do
        y1 = y1 - 1
    end
    while y2 + 1 < screen_height and
            is_native_panel_cell(interior_x, y2 + 1) do
        y2 = y2 + 1
    end
    return {x1=best_x1, y1=y1, x2=best_x2, y2=y2}
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
    it('proves native and overlay behavior with exact mount cleanup',
            function()
        assert.is_true(dfhack.world.isFortressMode(),
            'native acceptance requires a loaded fortress')
        assert.is_true(dfhack.gui.matchFocusString(
            'dwarfmode/Default', dfhack.gui.getDFViewscreen(true)),
            'native acceptance must start at dwarfmode/Default')
        assert.is_true(#df.global.plotinfo.hauling.routes > 10,
            'native acceptance requires a scrollable Hauling route list')

        local run = ds.current_run()
        run.native_overlay_events = {}
        overlay_config_path =
            dfhack.getDFPath() .. '/dfhack-config/overlay.json'
        overlay_config_existed =
            dfhack.filesystem.isfile(overlay_config_path)
        overlay_config_contents = overlay_config_existed and
            read_file(overlay_config_path) or nil
        staged = ds.stage_overlay_registration(
            'tests/automation/support/native_screen_overlay_probe.lua',
            'native_screen')
        overlay_name =
            'gui/' .. staged.script_name .. '.native_screen'
        assert.same({overlay_name}, staged.registered_names)
        assert.is_true(overlay.overlay_command(
            {'enable', overlay_name}, true))

        local native_screen = dfhack.gui.getDFViewscreen(true)
        local native_root = native_screen.widgets
        local original_current = dfhack.gui.getCurViewscreen(true)
        local original_focus = copy_array(dfhack.gui.getCurFocus(true))
        local original_stack = screen_stack()
        local original_pointer = pointer_state()
        local original_dispatcher = overlay.render_viewscreen_widgets
        local hauling = df.global.plotinfo.hauling
        local original_scroll = hauling.scroll_position

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

        local target = assert(named_native_child(native_root),
            'native root has no named direct child for lookup acceptance')
        local named = ds.get(target.name)
        local numeric = ds.get({target.index})
        assert.equals(named:raw(), numeric:raw())
        assert.equals(target.raw, named:raw())
        assert.equals(dfhack.gui.getWidget(native_root, target.name),
            named:raw())
        assert.same(dfhack.gui.getFocusStrings(native_screen),
            named:getFocusList())

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
        local probe = overlay_root:raw()
        assert.equals(
            overlay.get_state().db[overlay_name].widget, probe)
        assert.is_true(probe.render_count > 0)

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

        overlay_button:move_pointer('center')
        local button_x, button_y = dfhack.screen.getMousePos()
        local button_body = assert(overlay_button:inspect().body)
        assert.is_true(button_x >= button_body.x1 and
            button_x <= button_body.x2 and button_y >= button_body.y1 and
            button_y <= button_body.y2,
            'pointer must be over the rendered overlay button')
        ds.mouseInput(ds.EMouseButton.LEFT)
        assert.equals(1, probe.click_count)
        assert.equals('clicks: 1', ds.get('status', source):text())
        assert.is_true(probe.input_count > 0)
        ds.mouseInput(ds.EMouseButton.LEFT, ds.EInputState.DOWN)
        ds.mouseInput(ds.EMouseButton.LEFT, ds.EInputState.UP)

        ds.input('D_HAULING')
        ds.await('native Hauling screen opens', function()
            return dfhack.gui.matchFocusString(
                'dwarfmode/Hauling', native_screen)
        end)
        ds.redraw()
        local panel = assert(hauling_panel_bounds(11),
            'could not find the rendered native Hauling route panel')
        local list_x = math.min(panel.x1 + 2, panel.x2)
        local list_y = panel.y1 + 7
        assert.is_true(list_y <= panel.y2,
            'rendered Hauling panel does not contain a route row')
        assert.is_true(is_native_panel_cell(list_x, list_y),
            'pointer target must be a rendered native panel cell')
        local actual_x, actual_y = ds.move_pointer(list_x, list_y)
        assert.equals(list_x, actual_x)
        assert.equals(list_y, actual_y)
        assert.same({list_x, list_y},
            {dfhack.screen.getMousePos()})
        ds.mouseInput(ds.EMouseButton.SCROLL_DOWN)
        assert.is_true(hauling.scroll_position > original_scroll,
            'wheel input over the native route list must scroll it')

        hauling.scroll_position = original_scroll
        ds.input('LEAVESCREEN')
        ds.await('native Hauling screen closes', function()
            return dfhack.gui.matchFocusString(
                'dwarfmode/Default', native_screen)
        end)

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
        assert.equals(original_scroll, hauling.scroll_position)
        assert.equals(0, cleanup.active_screen_count)
        assert.equals(0, cleanup.tracked_screen_count)
        assert.equals(0, cleanup.owned_screen_count)
        assert.equals(0, cleanup.borrowed_native_screen_count)
        assert.equals(1, cleanup.native_attachment_count)
        assert.equals(0, cleanup.native_screen_dismissal_count)
        assert.equals(0, cleanup.subject_count)
        assert.is_false(cleanup.pointer_active)
        assert.is_false(cleanup.button_state_active)
        assert.is_false(cleanup.render_observer_active)

        local state = overlay.get_state()
        assert.is_table(state.db[overlay_name],
            'native unmount must not remove an external overlay')
        assert.is_true(state.config[overlay_name].enabled,
            'native unmount must not disable an external overlay')
    end)

    it('verifies independent overlay-registration restoration', function()
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
        assert.equals(1, run.native_overlay_events.enabled)
        assert.equals(1, run.native_overlay_events.disabled)
        assert.equals(overlay_config_existed,
            dfhack.filesystem.isfile(overlay_config_path))
        if overlay_config_existed then
            assert.equals(overlay_config_contents,
                read_file(overlay_config_path))
        end
    end)
end)
