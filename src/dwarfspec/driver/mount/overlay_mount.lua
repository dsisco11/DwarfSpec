-- Run-owned lifecycle emulation for isolated OverlayWidget mounts.

local M = {}

---Converts a one-based overlay position into DFHack frame anchors.
---@param position table
---@param old_frame table|nil
---@return table
local function make_frame(position, old_frame)
    old_frame = old_frame or {}
    local frame = {w=old_frame.w, h=old_frame.h}
    if position.x < 0 then
        frame.r = math.abs(position.x) - 1
    else
        frame.l = position.x - 1
    end
    if position.y < 0 then
        frame.b = math.abs(position.y) - 1
    else
        frame.t = position.y - 1
    end
    return frame
end

---Returns a stable run-owned logical name for an unnamed overlay.
---@param mount table
---@return string
local function logical_name(mount)
    local run_id = mount.run and mount.run.run_id or 'run'
    run_id = tostring(run_id):gsub('[^%w_.-]', '_')
    return ('dwarfspec.%s.%d'):format(run_id, mount.id)
end

---Creates isolated overlay lifecycle controllers with injected live services.
---@param options table
---@return table
function M.new(options)
    assert(type(options) == 'table',
        'overlay mount lifecycle requires dependency options')
    local gui_module = assert(options.gui_module,
        'overlay mount lifecycle requires gui')
    local get_value = options.get_value or require('utils').getval
    local now_ms = options.now_ms or function() return dfhack.getTickCount() end
    local random = options.random or math.random
    local get_backing_viewscreen = options.get_backing_viewscreen or
        function() return dfhack.gui.getCurViewscreen(true) end
    local get_rects = options.get_rects or function(viewport)
        if viewport then
            local dimensions = gui_module.mkdims_wh(
                0, 0, viewport.width, viewport.height)
            return gui_module.ViewRect{rect=dimensions},
                gui_module.ViewRect{rect=dimensions}
        end
        local width, height = dfhack.screen.getWindowSize()
        local full = gui_module.ViewRect{
            rect=gui_module.mkdims_wh(0, 0, width, height),
        }
        local scaled = gui_module.ViewRect{
            rect=gui_module.get_interface_rect(),
        }
        return full, scaled
    end

    ---@class dwarfspec.OverlayMountFactory
    local factory = {}

    ---Creates one controller without consulting the global overlay database.
    ---@param mount table
    ---@param widget table
    ---@param mount_options table
    ---@return table
    function factory:create(mount, widget, mount_options)
        assert(type(mount) == 'table' and type(mount.id) == 'number',
            'overlay controller requires a component mount')
        assert(type(widget) == 'table',
            'overlay controller requires an OverlayWidget instance')
        mount_options = mount_options or {}
        local original_name = widget.name
        assert(original_name == nil or
            (type(original_name) == 'string' and original_name ~= ''),
            'overlay logical name must be a nonempty string')
        local original_frame = widget.frame
        local position = mount_options.overlay_position or
            widget.default_pos or {x=1, y=1}
        widget.name = original_name or logical_name(mount)
        widget.frame = make_frame(position, original_frame)

        ---@class dwarfspec.OverlayMountController
        local controller = {
            widget=widget,
            backing_viewscreen=mount_options.backing_viewscreen or
                get_backing_viewscreen(),
            viewport=mount_options.viewport,
            original_name=original_name,
            original_frame=original_frame,
            enabled=false,
            restored=false,
            next_update_ms=0,
        }

        ---Returns the current full-window and scaled-interface rectangles.
        ---@return table, table
        function controller:rects()
            return get_rects(self.viewport)
        end

        ---Lays out the overlay using the same rect selection as DFHack.
        function controller:layout()
            local full, scaled = self:rects()
            self.widget:updateLayout(self.widget.fullscreen and full or scaled)
        end

        ---Runs a callback and refreshes layout if its frame size changed.
        ---@param callback function
        ---@return any
        function controller:with_frame_change(callback)
            local frame = self.widget.frame
            local width, height = frame.w, frame.h
            local result = callback()
            if width ~= frame.w or height ~= frame.h then
                self.widget:updateLayout()
            end
            return result
        end

        ---Enables the isolated overlay after its frame and layout are ready.
        function controller:enable()
            if self.enabled then return end
            self:layout()
            self.enabled = true
            if self.widget.overlay_onenable then
                self.widget.overlay_onenable()
            end
        end

        ---Runs one eligible throttled overlay update.
        ---@return any
        function controller:update()
            if not self.enabled or not self.widget.overlay_onupdate then
                return nil
            end
            local current_ms = now_ms()
            local frequency = self.widget
                .overlay_onupdate_max_freq_seconds or 5
            if frequency ~= 0 and self.next_update_ms > current_ms then
                return nil
            end
            if not get_value(self.widget.active) then return nil end
            if frequency == 0 then
                self.next_update_ms = current_ms
            else
                local frequency_ms = math.floor(frequency * 1000)
                local jitter = random(0, frequency_ms // 8)
                self.next_update_ms = current_ms + frequency_ms - jitter
            end
            return self:with_frame_change(function()
                return self.widget:overlay_onupdate(
                    self.backing_viewscreen)
            end)
        end

        ---Feeds input when the isolated overlay is active and visible.
        ---@param keys table
        ---@return boolean
        function controller:input(keys)
            if not self.enabled or not get_value(self.widget.active) or
                    not get_value(self.widget.visible) then
                return false
            end
            return not not self:with_frame_change(function()
                return self.widget:onInput(keys)
            end)
        end

        ---Renders a visible overlay with the DFHack overlay painter contract.
        function controller:render()
            if not self.enabled or not get_value(self.widget.visible) then
                return
            end
            local full, scaled = self:rects()
            self:with_frame_change(function()
                self.widget:render(gui_module.Painter.new(
                    self.widget.fullscreen and full or scaled))
            end)
        end

        ---Disables the isolated overlay exactly once.
        function controller:disable()
            if not self.enabled then return end
            self.enabled = false
            if self.widget.overlay_ondisable then
                self.widget.overlay_ondisable()
            end
        end

        ---Restores the caller-owned name and frame exactly once.
        function controller:restore()
            if self.restored then return end
            self.restored = true
            self.widget.name = self.original_name
            self.widget.frame = self.original_frame
        end

        return controller
    end

    return factory
end

return M
