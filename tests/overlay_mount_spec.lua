-- Unit contracts for isolated OverlayWidget lifecycle emulation.

local overlay_mount = assert(loadfile(
    'src/dwarfspec/overlay_mount.lua'))()

describe('DwarfSpec overlay mount lifecycle', function()
    local current_ms
    local factory

    before_each(function()
        current_ms = 0
        factory = overlay_mount.new({
            gui_module={
                Painter={
                    new=function(rect) return {rect=rect} end,
                },
            },
            get_value=function(value)
                if type(value) == 'function' then return value() end
                return value
            end,
            get_backing_viewscreen=function()
                return {kind='default-backing'}
            end,
            get_rects=function()
                return {kind='full'}, {kind='scaled'}
            end,
            now_ms=function() return current_ms end,
            random=function() return 0 end,
        })
    end)

    it('matches overlay layout, update, render, input, and cleanup rules',
            function()
        local events = {}
        local original_frame = {w=5, h=2, l=40}
        local backing = {kind='viewscreen'}
        local active = true
        local visible = true
        local widget = {
            active=function() return active end,
            visible=function() return visible end,
            default_pos={x=-2, y=3},
            frame=original_frame,
            full_interface=true,
            fullscreen=false,
            overlay_onupdate_max_freq_seconds=1,
            updateLayout=function(self, rect)
                table.insert(events, {'layout', rect and rect.kind})
            end,
            overlay_onenable=function()
                table.insert(events, {'enable'})
            end,
            overlay_onupdate=function(self, viewscreen)
                table.insert(events, {'update', viewscreen})
            end,
            onInput=function(self, keys)
                table.insert(events, {'input', keys})
                self.frame.w = self.frame.w + 1
                return true
            end,
            render=function(self, painter)
                table.insert(events, {'render', painter.rect.kind})
            end,
            overlay_ondisable=function()
                table.insert(events, {'disable'})
            end,
        }
        local controller = factory:create({
            id=7,
            run={run_id='live-run'},
        }, widget, {backing_viewscreen=backing})

        assert.equals('dwarfspec.live-run.7', widget.name)
        assert.same({w=5, h=2, r=1, t=2}, widget.frame)
        controller:enable()
        controller:render()
        controller:update()
        current_ms = 500
        controller:update()
        current_ms = 1000
        controller:update()
        assert.same({
            {'layout', 'scaled'},
            {'enable'},
            {'render', 'scaled'},
            {'update', backing},
            {'update', backing},
        }, events)

        active = false
        current_ms = 2000
        controller:update()
        assert.equals(5, #events)
        active = true
        controller:update()
        visible = false
        controller:render()
        assert.is_false(controller:input({SELECT=true}))
        visible = true
        local keys = {SELECT=true}
        assert.is_true(controller:input(keys))
        assert.same({'layout', nil}, events[#events])

        widget.fullscreen = true
        controller:layout()
        controller:render()
        assert.same({'render', 'full'}, events[#events])
        controller:disable()
        controller:disable()
        assert.same({'disable'}, events[#events])
        controller:restore()
        controller:restore()
        assert.is_nil(widget.name)
        assert.equals(original_frame, widget.frame)
    end)

    it('preserves explicit names and applies test-local positioning',
            function()
        local original_frame = {w=9, h=4, b=3}
        local widget = {
            name='consumer.overlay',
            frame=original_frame,
            default_pos={x=8, y=9},
            updateLayout=function() end,
        }
        local controller = factory:create({id=2, run={run_id='r'}},
            widget, {overlay_position={x=4, y=-6}})

        assert.equals('consumer.overlay', widget.name)
        assert.equals('default-backing',
            controller.backing_viewscreen.kind)
        assert.same({w=9, h=4, l=3, b=5}, widget.frame)
        controller:restore()
        assert.equals('consumer.overlay', widget.name)
        assert.equals(original_frame, widget.frame)
    end)
end)
