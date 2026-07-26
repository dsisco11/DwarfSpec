-- Unit contracts for live interaction support utilities without DFHack state.

local cleanup = assert(loadfile(
    'src/dwarfspec/automation/cleanup.lua'))()
local diagnostics = assert(loadfile(
    'src/dwarfspec/automation/diagnostics.lua'))()
local pointer_adapter = assert(loadfile(
    'src/dwarfspec/automation/pointer_adapter.lua'))()

describe('automation interaction support', function()
    local original_dfhack
    local original_df

    before_each(function()
        original_dfhack = rawget(_G, 'dfhack')
        original_df = rawget(_G, 'df')
        rawset(_G, 'dfhack', {
            screen={
                getMousePos=function() return 90, 91 end,
                getWindowSize=function() return 3, 2 end,
                readTile=function(x, y)
                    return {ch=65 + x + y, fg=7, bg=0, bold=false}
                end,
            },
        })
        rawset(_G, 'df', {
            global={
                gps={mouse_x=4, mouse_y=5},
                enabler={
                    mouse_focus=false,
                    tracking_on=0,
                    mouse_lbut_down=0,
                    mouse_lbut_lift=0,
                    mouse_rbut_down=0,
                    mouse_rbut_lift=0,
                    mouse_mbut_down=0,
                    mouse_mbut_lift=0,
                },
            },
        })
    end)

    after_each(function()
        rawset(_G, 'dfhack', original_dfhack)
        rawset(_G, 'df', original_df)
    end)

    it('captures stable view and screen diagnostics without mutation', function()
        local child = {
            _type='Label',
            view_id='child',
            visible=true,
            active=true,
            text='Child text',
            tooltip='Child tooltip',
            frame_rect={x1=1, y1=2, x2=3, y2=2},
            frame_body={x1=1, y1=2, x2=3, y2=2},
            subviews={},
            hasFocus=function() return true end,
        }
        local root = {
            _type='Panel',
            view_id='root',
            visible=true,
            active=true,
            frame_rect={x1=0, y1=0, x2=4, y2=3},
            frame_body={x1=0, y1=0, x2=4, y2=3},
            subviews={child},
            hasFocus=function() return false end,
        }

        local inspection = diagnostics.inspect_view(child)
        local tree = diagnostics.capture_view_tree(root)
        local capture = diagnostics.capture_screen{max_width=2, max_height=1}

        assert.same('Label', inspection.class)
        assert.is_true(inspection.focused)
        assert.equals('Child text', inspection.text)
        assert.same('root', tree.view_id)
        assert.same('child', tree.children[1].view_id)
        assert.equals('Panel#root,>Label#child', diagnostics.summarize_tree(tree))
        assert.same(2, capture.width)
        assert.same(1, capture.height)
        assert.same(65, capture.cells[1][1].ch)
    end)

    it('reports native widget focus without requiring hasFocus()', function()
        local inspection = diagnostics.inspect_view({
            _type='EditField',
            visible=true,
            active=true,
            focus=true,
        })

        assert.is_true(inspection.focused)
    end)

    it('reads fresh validated geometry from the injected provider', function()
        local calls = 0
        local supplied = {
            grid_width=4,
            grid_height=3,
            pixel_width=43,
            pixel_height=25,
            cell_pixel_width=10,
            cell_pixel_height=8,
        }
        local adapter = pointer_adapter.new(cleanup, cleanup.new({}), {
            get_geometry=function()
                calls = calls + 1
                return supplied
            end,
        })

        local first = pointer_adapter.geometry(adapter)
        supplied.grid_width = 5
        local second = pointer_adapter.geometry(adapter)

        assert.equals(2, calls)
        assert.equals(4, first.grid_width)
        assert.equals(5, second.grid_width)
        assert.is_not.equal(supplied, second)
    end)

    it('normalizes non-square grid cells to their center pixels', function()
        local position = pointer_adapter.normalize_position(2, 1, 'grid', {
            grid_width=4,
            grid_height=3,
            pixel_width=43,
            pixel_height=25,
            cell_pixel_width=10,
            cell_pixel_height=8,
        })

        assert.same({x=2, y=1}, position.grid)
        assert.same({x=25, y=12}, position.pixels)
    end)

    it('preserves exact pixels while deriving their grid cell', function()
        local position = pointer_adapter.normalize_position(
            21, 17, 'pixels', {
                grid_width=4,
                grid_height=3,
                pixel_width=43,
                pixel_height=25,
                cell_pixel_width=10,
                cell_pixel_height=8,
            })

        assert.same({x=2, y=2}, position.grid)
        assert.same({x=21, y=17}, position.pixels)
    end)

    it('clamps residual right and bottom pixels to the last grid cell',
            function()
        local position = pointer_adapter.normalize_position(
            42, 24, 'pixels', {
                grid_width=4,
                grid_height=3,
                pixel_width=43,
                pixel_height=25,
                cell_pixel_width=10,
                cell_pixel_height=8,
            })

        assert.same({x=3, y=2}, position.grid)
        assert.same({x=42, y=24}, position.pixels)
    end)

    it('rejects every invalid coordinate category on both axes', function()
        local geometry = {
            grid_width=4,
            grid_height=3,
            pixel_width=43,
            pixel_height=25,
            cell_pixel_width=10,
            cell_pixel_height=8,
        }
        local cases = {
            {nil, 0, 'grid',
                'grid x coordinate must be an integer; got nil'},
            {'1', 0, 'grid',
                'grid x coordinate must be an integer; got 1'},
            {1.5, 0, 'grid',
                'grid x coordinate must be an integer; got 1.5'},
            {-1, 0, 'grid',
                'grid x coordinate -1 is outside [0, 3]'},
            {4, 0, 'grid',
                'grid x coordinate 4 is outside [0, 3]'},
            {0, nil, 'grid',
                'grid y coordinate must be an integer; got nil'},
            {0, '1', 'grid',
                'grid y coordinate must be an integer; got 1'},
            {0, 1.5, 'grid',
                'grid y coordinate must be an integer; got 1.5'},
            {0, -1, 'grid',
                'grid y coordinate -1 is outside [0, 2]'},
            {0, 3, 'grid',
                'grid y coordinate 3 is outside [0, 2]'},
            {nil, 0, 'pixels',
                'pixels x coordinate must be an integer; got nil'},
            {'1', 0, 'pixels',
                'pixels x coordinate must be an integer; got 1'},
            {1.5, 0, 'pixels',
                'pixels x coordinate must be an integer; got 1.5'},
            {-1, 0, 'pixels',
                'pixels x coordinate -1 is outside [0, 42]'},
            {43, 0, 'pixels',
                'pixels x coordinate 43 is outside [0, 42]'},
            {0, nil, 'pixels',
                'pixels y coordinate must be an integer; got nil'},
            {0, '1', 'pixels',
                'pixels y coordinate must be an integer; got 1'},
            {0, 1.5, 'pixels',
                'pixels y coordinate must be an integer; got 1.5'},
            {0, -1, 'pixels',
                'pixels y coordinate -1 is outside [0, 24]'},
            {0, 25, 'pixels',
                'pixels y coordinate 25 is outside [0, 24]'},
        }

        for _, case in ipairs(cases) do
            assert.has_error(function()
                pointer_adapter.normalize_position(
                    case[1], case[2], case[3], geometry)
            end, case[4])
        end
        assert.has_error(function()
            pointer_adapter.normalize_position(0, 0, 'tiles', geometry)
        end, 'unsupported pointer coordinate space: tiles')
    end)

    it('rejects every invalid effective-geometry field', function()
        local valid = {
            grid_width=4,
            grid_height=3,
            pixel_width=43,
            pixel_height=25,
            cell_pixel_width=10,
            cell_pixel_height=8,
        }
        local fields = {
            {name='grid_width', gps_name='dimx'},
            {name='grid_height', gps_name='dimy'},
            {name='pixel_width', gps_name='screen_pixel_x'},
            {name='pixel_height', gps_name='screen_pixel_y'},
            {name='cell_pixel_width', gps_name='tile_pixel_x'},
            {name='cell_pixel_height', gps_name='tile_pixel_y'},
        }
        local invalid_values = {
            {label='nil'},
            {value='bad', label='bad'},
            {value=0, label='0'},
            {value=-1, label='-1'},
            {value=1.5, label='1.5'},
        }

        assert.has_error(function()
            pointer_adapter.validate_geometry(false)
        end, 'pointer geometry must be a table')
        for _, field in ipairs(fields) do
            for _, invalid in ipairs(invalid_values) do
                local geometry = {}
                for name, value in pairs(valid) do geometry[name] = value end
                geometry[field.name] = invalid.value
                assert.has_error(function()
                    pointer_adapter.validate_geometry(geometry)
                end, ('pointer geometry gps.%s must be a positive integer; ' ..
                    'got %s'):format(field.gps_name, invalid.label))
            end
        end
    end)

    it('restores the virtual pointer and temporary native click position', function()
        local registry = cleanup.new({})
        local adapter = pointer_adapter.new(cleanup, registry)
        local original_pointer = dfhack.screen.getMousePos

        assert.has_error(function() pointer_adapter.position(adapter) end,
            'mouse input requires a pointer position; call ' ..
            'ds.move_pointer() or subject:hover() first')
        pointer_adapter.set(adapter, 10, 11)
        assert.same({10, 11}, {dfhack.screen.getMousePos()})
        assert.same({10, 11}, {pointer_adapter.position(adapter)})
        local observed_x
        local observed_y
        pointer_adapter.with_interface_mouse(12, 13, function()
            observed_x = df.global.gps.mouse_x
            observed_y = df.global.gps.mouse_y
            assert.is_true(df.global.enabler.mouse_focus)
            assert.equals(1, df.global.enabler.tracking_on)
        end)
        assert.same({12, 13}, {observed_x, observed_y})
        assert.same({4, 5}, {df.global.gps.mouse_x, df.global.gps.mouse_y})
        assert.is_false(df.global.enabler.mouse_focus)
        assert.equals(0, df.global.enabler.tracking_on)

        local input_ok, input_error = pcall(function()
            pointer_adapter.with_interface_mouse(14, 15, function()
                error('simulated input failed', 0)
            end)
        end)
        assert.is_false(input_ok)
        assert.matches('simulated input failed', input_error, 1, true)
        assert.same({4, 5}, {df.global.gps.mouse_x, df.global.gps.mouse_y})
        assert.is_false(df.global.enabler.mouse_focus)
        assert.equals(0, df.global.enabler.tracking_on)

        pointer_adapter.clear(adapter)
        assert.equals(original_pointer, dfhack.screen.getMousePos)
        assert.equals(0, cleanup.pending_count(registry))
    end)

    it('holds and releases native button state with cleanup restoration',
            function()
        local registry = cleanup.new({})
        local adapter = pointer_adapter.new(cleanup, registry)

        pointer_adapter.with_button_state(adapter,
            'mouse_lbut_down', 'mouse_lbut_lift', true, function()
                assert.equals(1, df.global.enabler.mouse_lbut_down)
                assert.equals(0, df.global.enabler.mouse_lbut_lift)
            end)
        assert.equals(1, df.global.enabler.mouse_lbut_down)
        assert.equals(0, df.global.enabler.mouse_lbut_lift)
        assert.is_true(df.global.enabler.mouse_focus)
        assert.equals(1, df.global.enabler.tracking_on)

        pointer_adapter.with_button_state(adapter,
            'mouse_lbut_down', 'mouse_lbut_lift', false, function()
                assert.equals(0, df.global.enabler.mouse_lbut_down)
                assert.equals(1, df.global.enabler.mouse_lbut_lift)
            end)
        assert.equals(0, df.global.enabler.mouse_lbut_down)
        assert.equals(0, df.global.enabler.mouse_lbut_lift)
        assert.is_false(df.global.enabler.mouse_focus)
        assert.equals(0, df.global.enabler.tracking_on)

        local transition_ok, transition_error = pcall(function()
            pointer_adapter.with_button_state(adapter,
                'mouse_rbut_down', 'mouse_rbut_lift', true, function()
                    error('button transition failed', 0)
                end)
        end)
        assert.is_false(transition_ok)
        assert.matches('button transition failed', transition_error, 1, true)
        assert.equals(0, df.global.enabler.mouse_rbut_down)
        assert.equals(0, df.global.enabler.mouse_rbut_lift)

        pointer_adapter.with_button_state(adapter,
            'mouse_lbut_down', 'mouse_lbut_lift', true, function() end)
        local cleanup_ok = cleanup.run(registry, 'button state test')
        assert.is_true(cleanup_ok)
        assert.equals(0, df.global.enabler.mouse_lbut_down)
        assert.is_false(df.global.enabler.mouse_focus)
        assert.equals(0, df.global.enabler.tracking_on)
        assert.equals(0, cleanup.pending_count(registry))
    end)

    it('rejects restoration if another owner replaces the pointer function', function()
        local registry = cleanup.new({})
        local adapter = pointer_adapter.new(cleanup, registry)
        pointer_adapter.set(adapter, 10, 11)
        dfhack.screen.getMousePos = function() return 0, 0 end

        local first_ok, first_failures = cleanup.run(registry, 'conflict proof')
        assert.is_false(first_ok)
        assert.equals(1, #first_failures)
        local ok, failures = cleanup.run(registry, 'post-conflict proof')
        assert.is_true(ok)
        assert.equals(1, #registry.failures)
        assert.matches('changed externally', registry.failures[1].message,
            1, true)
        assert.same(0, #failures)
    end)
end)
