-- Live contracts for mounted-component interaction, inspection, and capture.

local widgets = require('gui.widgets')

local POINTER_BUTTON_FIELDS = {
    'mouse_focus',
    'tracking_on',
    'mouse_lbut_down',
    'mouse_lbut_lift',
    'mouse_rbut_down',
    'mouse_rbut_lift',
    'mouse_mbut_down',
    'mouse_mbut_lift',
}

---Captures every pointer accessor, raw coordinate, and input-state field.
---@return table
local function pointer_state()
    local state = {
        get_mouse_pos=dfhack.screen.getMousePos,
        get_mouse_pixels=dfhack.screen.getMousePixels,
        gui_get_mouse_pos=dfhack.gui.getMousePos,
        mouse_x=df.global.gps.mouse_x,
        mouse_y=df.global.gps.mouse_y,
        precise_mouse_x=df.global.gps.precise_mouse_x,
        precise_mouse_y=df.global.gps.precise_mouse_y,
    }
    for _, field in ipairs(POINTER_BUTTON_FIELDS) do
        state[field] = df.global.enabler[field]
    end
    return state
end

---Asserts exact equality for two complete pointer snapshots.
---@param expected table
---@param actual table
local function assert_pointer_state(expected, actual)
    for name, value in pairs(expected) do
        assert.equals(value, actual[name], name)
    end
    for name, value in pairs(actual) do
        assert.equals(value, expected[name], name)
    end
end

---Reads the current effective grid-to-pixel geometry from Premium DF.
---@return table
local function pointer_geometry()
    return {
        grid_width=df.global.gps.dimx,
        grid_height=df.global.gps.dimy,
        pixel_width=df.global.gps.screen_pixel_x,
        pixel_height=df.global.gps.screen_pixel_y,
        cell_pixel_width=df.global.gps.tile_pixel_x,
        cell_pixel_height=df.global.gps.tile_pixel_y,
    }
end

---Returns the center pixel associated with one UI-grid cell.
---@param grid_x integer
---@param grid_y integer
---@param geometry table
---@return integer, integer
local function grid_center_pixels(grid_x, grid_y, geometry)
    return grid_x * geometry.cell_pixel_width +
            math.floor(geometry.cell_pixel_width / 2),
        grid_y * geometry.cell_pixel_height +
            math.floor(geometry.cell_pixel_height / 2)
end

---Asserts both accessors and all four raw pointer coordinates.
---@param grid_x integer
---@param grid_y integer
---@param pixel_x integer
---@param pixel_y integer
local function assert_pointer_position(grid_x, grid_y, pixel_x, pixel_y)
    assert.same({grid_x, grid_y}, {dfhack.screen.getMousePos()})
    assert.same({pixel_x, pixel_y}, {dfhack.screen.getMousePixels()})
    assert.equals(grid_x, df.global.gps.mouse_x)
    assert.equals(grid_y, df.global.gps.mouse_y)
    assert.equals(pixel_x, df.global.gps.precise_mouse_x)
    assert.equals(pixel_y, df.global.gps.precise_mouse_y)
end

---Counts pending virtual-pointer cleanup claims in the current run.
---@param run table
---@return integer
local function pointer_cleanup_claim_count(run)
    local count = 0
    for _, entry in ipairs(run.cleanup_registry.entries) do
        if entry.name == 'virtual pointer' and entry.state == 'pending' then
            count = count + 1
        end
    end
    return count
end

---@class tests.AutomationInteractionWidget: widgets.Panel
local AutomationInteractionWidget = defclass(nil, widgets.Panel)
AutomationInteractionWidget.ATTRS{
    view_id='interaction_root',
    frame={w=32, h=8},
}

---Builds the deterministic mounted widget tree.
function AutomationInteractionWidget:init()
    self.click_count = 0
    self.typed_text = ''
    self.last_key = nil
    self.last_pointer_input = nil
    self.target = widgets.Label{
        view_id='tooltip_target',
        frame={l=1, t=1, w=20, h=1},
        text='Automation target',
        tooltip='Automation tooltip',
    }
    self.input = widgets.Label{
        view_id='input_echo',
        frame={l=1, t=3, w=28, h=1},
        text='Typed: ',
    }
    self.clicks = widgets.Label{
        view_id='click_echo',
        frame={l=1, t=5, w=28, h=1},
        text='Clicks: 0',
    }
    self:addviews{self.target, self.input, self.clicks}
end

---Updates test tooltip text before ordinary component rendering.
---@param dc gui.Painter
function AutomationInteractionWidget:render(dc)
    local x, y = dfhack.screen.getMousePos()
    local body = self.target.frame_body
    if x and y and body and body:inClipGlobalXY(x, y) then
        local local_x, local_y = body:localXY(x, y)
        self.target.tooltip = ('Automation hover %d,%d'):format(
            local_x, local_y)
    end
    AutomationInteractionWidget.super.render(self, dc)
end

---Handles synthetic input through ordinary mounted-widget dispatch.
---@param keys table
---@return boolean
function AutomationInteractionWidget:onInput(keys)
    if keys._STRING and keys._STRING ~= 0 then
        self.typed_text = self.typed_text .. string.char(keys._STRING)
        self.input:setText('Typed: ' .. self.typed_text)
        return true
    end
    if keys._MOUSE_L then
        local x, y = dfhack.screen.getMousePos()
        local pixel_x, pixel_y = dfhack.screen.getMousePixels()
        self.last_pointer_input = {
            grid_x=x,
            grid_y=y,
            pixel_x=pixel_x,
            pixel_y=pixel_y,
            raw_grid_x=df.global.gps.mouse_x,
            raw_grid_y=df.global.gps.mouse_y,
            raw_pixel_x=df.global.gps.precise_mouse_x,
            raw_pixel_y=df.global.gps.precise_mouse_y,
        }
        if self.target.frame_body:inClipGlobalXY(x, y) then
            self.click_count = self.click_count + 1
            self.clicks:setText('Clicks: ' .. self.click_count)
            return true
        end
    end
    for key in pairs(keys) do
        if type(key) == 'string' and key:match('^CUSTOM_') then
            self.last_key = key
            return true
        end
    end
    return AutomationInteractionWidget.super.onInput(self, keys)
end

describe('automation live interactions', function()
    after_each(function()
        pcall(ds.unmount)
    end)

    it('mounts, selects, inspects, interacts, captures, and unmounts',
            function()
        local initial_pause_state = df.global.pause_state
        local initial_pointer = pointer_state()
        local run = ds.current_run()
        local root = ds.mount(AutomationInteractionWidget)
        local target = ds.get('tooltip_target')
        local input = ds.get('input_echo')
        local component = root:raw()

        local inspection = target:inspect()
        local tree = ds.capture_view_tree('interaction-tree')
        assert.equals('tooltip_target', inspection.view_id)
        assert.is_true(inspection.visible)
        assert.is_truthy(inspection.body)
        assert.equals('interaction_root', tree.view_id)
        assert.equals(0, component.click_count)

        target:move_pointer()
        assert.matches('^Automation hover %d+,%d+$', target:raw().tooltip)
        target:click()
        assert.equals(1, component.click_count)
        root:type('Hi')
        assert.equals('Hi', component.typed_text)
        assert.equals('Typed: Hi', input:text())
        root:input('CUSTOM_A')
        assert.equals('CUSTOM_A', component.last_key)

        local capture = ds.capture_screen('interaction-cells', {
            max_width=8,
            max_height=4,
        })
        assert.equals(8, capture.width)
        assert.equals(4, capture.height)
        assert.equals(4, #capture.cells)

        ds.unmount()
        assert_pointer_state(initial_pointer, pointer_state())
        assert.equals(initial_pause_state, df.global.pause_state)
        assert.is_false(run.mount_cleanup_probe().pointer_active)
        assert.is_false(run.mount_cleanup_probe().button_state_active)
    end)

    it('synchronizes grid, pixel, subject, input, and cleanup state',
            function()
        local original_pointer = pointer_state()
        local geometry = pointer_geometry()
        local run = ds.current_run()
        local root = ds.mount(AutomationInteractionWidget)
        local target = ds.get('tooltip_target')
        local component = root:raw()

        local default_x = math.min(2, geometry.grid_width - 1)
        local default_y = math.min(3, geometry.grid_height - 1)
        local default_pixel_x, default_pixel_y =
            grid_center_pixels(default_x, default_y, geometry)
        assert.same({default_x, default_y},
            {ds.move_pointer(default_x, default_y)})
        assert_pointer_position(default_x, default_y,
            default_pixel_x, default_pixel_y)
        assert.equals(1, pointer_cleanup_claim_count(run))
        assert.is_true(run.mount_cleanup_probe().pointer_active)

        local grid_x = math.min(5, geometry.grid_width - 1)
        local grid_y = math.min(4, geometry.grid_height - 1)
        local grid_pixel_x, grid_pixel_y =
            grid_center_pixels(grid_x, grid_y, geometry)
        assert.same({grid_x, grid_y},
            {ds.move_pointer(grid_x, grid_y, ds.EPointerSpace.GRID)})
        assert_pointer_position(grid_x, grid_y, grid_pixel_x, grid_pixel_y)
        assert.equals(1, pointer_cleanup_claim_count(run))

        local pixel_x = math.min(geometry.pixel_width - 1,
            grid_x * geometry.cell_pixel_width +
                math.min(1, geometry.cell_pixel_width - 1))
        local pixel_y = math.min(geometry.pixel_height - 1,
            grid_y * geometry.cell_pixel_height +
                math.min(1, geometry.cell_pixel_height - 1))
        local derived_grid_x = math.min(
            math.floor(pixel_x / geometry.cell_pixel_width),
            geometry.grid_width - 1)
        local derived_grid_y = math.min(
            math.floor(pixel_y / geometry.cell_pixel_height),
            geometry.grid_height - 1)
        assert.same({pixel_x, pixel_y},
            {ds.move_pointer(pixel_x, pixel_y, ds.EPointerSpace.PIXELS)})
        assert_pointer_position(derived_grid_x, derived_grid_y,
            pixel_x, pixel_y)
        assert.equals(1, pointer_cleanup_claim_count(run))
        ds.wait_frames(2)
        df.global.gps.mouse_x = -1
        df.global.gps.mouse_y = -1
        df.global.gps.precise_mouse_x = -1
        df.global.gps.precise_mouse_y = -1
        dfhack.gui.getMousePos(true)
        assert.equals(derived_grid_x, df.global.gps.mouse_x)
        assert.equals(derived_grid_y, df.global.gps.mouse_y)
        assert.equals(pixel_x, df.global.gps.precise_mouse_x)
        assert.equals(pixel_y, df.global.gps.precise_mouse_y)

        local body = assert(target:inspect().body)
        assert.equals(target, target:move_pointer('center'))
        local subject_x, subject_y = dfhack.screen.getMousePos()
        assert.equals(math.floor((body.x1 + body.x2) / 2), subject_x)
        assert.equals(math.floor((body.y1 + body.y2) / 2), subject_y)
        local subject_pixel_x, subject_pixel_y =
            grid_center_pixels(subject_x, subject_y, geometry)
        assert_pointer_position(subject_x, subject_y,
            subject_pixel_x, subject_pixel_y)

        df.global.gps.mouse_x = -1
        df.global.gps.mouse_y = -1
        df.global.gps.precise_mouse_x = -1
        df.global.gps.precise_mouse_y = -1
        ds.mouseInput(ds.EMouseButton.LEFT)
        assert.equals(1, component.click_count)
        assert.same({
            grid_x=subject_x,
            grid_y=subject_y,
            pixel_x=subject_pixel_x,
            pixel_y=subject_pixel_y,
            raw_grid_x=subject_x,
            raw_grid_y=subject_y,
            raw_pixel_x=subject_pixel_x,
            raw_pixel_y=subject_pixel_y,
        }, component.last_pointer_input)
        assert_pointer_position(subject_x, subject_y,
            subject_pixel_x, subject_pixel_y)

        ds.unmount()
        assert_pointer_state(original_pointer, pointer_state())
        assert.equals(0, pointer_cleanup_claim_count(run))
        local cleanup = run.mount_cleanup_probe()
        assert.is_false(cleanup.pointer_active)
        assert.is_false(cleanup.button_state_active)
    end)
end)
