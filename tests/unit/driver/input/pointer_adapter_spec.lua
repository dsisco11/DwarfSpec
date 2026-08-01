-- Unit contracts for live interaction support utilities without DFHack state.

local cleanup = assert(loadfile(
    'src/dwarfspec/host/execution/cleanup.lua'))()
local diagnostics_module = assert(loadfile(
    'src/dwarfspec/driver/diagnostics/diagnostics.lua'))()
local pointer_adapter = assert(loadfile(
    'src/dwarfspec/driver/input/pointer_adapter.lua'))()
local EPointerSpace = require('dwarfspec.driver.input.pointer_spaces')

---Creates one paired logical pointer position for adapter tests.
---@param grid_x integer
---@param grid_y integer
---@param pixel_x integer
---@param pixel_y integer
---@return table
local function paired_position(grid_x, grid_y, pixel_x, pixel_y)
    return {
        grid={x=grid_x, y=grid_y},
        pixels={x=pixel_x, y=pixel_y},
    }
end

---Creates isolated pointer boundaries without reading DFHack globals.
---@param original_raw table|nil
---@return table
local function pointer_fixture(original_raw)
    original_raw = original_raw or {}
    local original_get_mouse_pos = function() return 90, 91 end
    local original_get_mouse_pixels = function() return 900, 910 end
    local screen = {
        getMousePos=original_get_mouse_pos,
        getMousePixels=original_get_mouse_pixels,
    }
    local gps = {
        mouse_x=original_raw.mouse_x or 4,
        mouse_y=original_raw.mouse_y or 5,
        precise_mouse_x=original_raw.precise_mouse_x or 40,
        precise_mouse_y=original_raw.precise_mouse_y or 50,
        dimx=80,
        dimy=25,
        screen_pixel_x=800,
        screen_pixel_y=250,
        tile_pixel_x=10,
        tile_pixel_y=10,
    }
    local gui_calls = {}
    local original_gui_get_mouse_pos = function(allow_out_of_bounds)
        table.insert(gui_calls, allow_out_of_bounds)
        return {
            x=gps.precise_mouse_x,
            y=gps.precise_mouse_y,
            z=allow_out_of_bounds and 1 or 0,
        }, 'map-result'
    end
    local gui = {
        getMousePos=original_gui_get_mouse_pos,
    }
    local enabler = {
        mouse_focus=false,
        tracking_on=0,
        mouse_lbut_down=0,
        mouse_lbut_lift=0,
        mouse_rbut_down=0,
        mouse_rbut_lift=0,
        mouse_mbut_down=0,
        mouse_mbut_lift=0,
    }
    local registry = cleanup.new({})
    return {
        screen=screen,
        gui=gui,
        gui_calls=gui_calls,
        gps=gps,
        enabler=enabler,
        registry=registry,
        original_get_mouse_pos=original_get_mouse_pos,
        original_get_mouse_pixels=original_get_mouse_pixels,
        original_gui_get_mouse_pos=original_gui_get_mouse_pos,
        adapter=pointer_adapter.new(cleanup, registry, {
            get_geometry=function()
                return {
                    grid_width=gps.dimx,
                    grid_height=gps.dimy,
                    pixel_width=gps.screen_pixel_x,
                    pixel_height=gps.screen_pixel_y,
                    cell_pixel_width=gps.tile_pixel_x,
                    cell_pixel_height=gps.tile_pixel_y,
                }
            end,
            screen=screen,
            gui=gui,
            gps=gps,
            enabler=enabler,
        }),
    }
end

describe('automation interaction support', function()
    local original_dfhack
    local original_df
    local diagnostics

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
        diagnostics = diagnostics_module.new({
            get_window_size=function()
                return dfhack.screen.getWindowSize()
            end,
            read_tile=function(x, y)
                return dfhack.screen.readTile(x, y)
            end,
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
        local position = pointer_adapter.normalize_position(
            2, 1, EPointerSpace.GRID, {
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
            21, 17, EPointerSpace.PIXELS, {
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
            42, 24, EPointerSpace.PIXELS, {
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
            {nil, 0, EPointerSpace.GRID,
                'grid x coordinate must be an integer; got nil'},
            {'1', 0, EPointerSpace.GRID,
                'grid x coordinate must be an integer; got 1'},
            {1.5, 0, EPointerSpace.GRID,
                'grid x coordinate must be an integer; got 1.5'},
            {-1, 0, EPointerSpace.GRID,
                'grid x coordinate -1 is outside [0, 3]'},
            {4, 0, EPointerSpace.GRID,
                'grid x coordinate 4 is outside [0, 3]'},
            {0, nil, EPointerSpace.GRID,
                'grid y coordinate must be an integer; got nil'},
            {0, '1', EPointerSpace.GRID,
                'grid y coordinate must be an integer; got 1'},
            {0, 1.5, EPointerSpace.GRID,
                'grid y coordinate must be an integer; got 1.5'},
            {0, -1, EPointerSpace.GRID,
                'grid y coordinate -1 is outside [0, 2]'},
            {0, 3, EPointerSpace.GRID,
                'grid y coordinate 3 is outside [0, 2]'},
            {nil, 0, EPointerSpace.PIXELS,
                'pixels x coordinate must be an integer; got nil'},
            {'1', 0, EPointerSpace.PIXELS,
                'pixels x coordinate must be an integer; got 1'},
            {1.5, 0, EPointerSpace.PIXELS,
                'pixels x coordinate must be an integer; got 1.5'},
            {-1, 0, EPointerSpace.PIXELS,
                'pixels x coordinate -1 is outside [0, 42]'},
            {43, 0, EPointerSpace.PIXELS,
                'pixels x coordinate 43 is outside [0, 42]'},
            {0, nil, EPointerSpace.PIXELS,
                'pixels y coordinate must be an integer; got nil'},
            {0, '1', EPointerSpace.PIXELS,
                'pixels y coordinate must be an integer; got 1'},
            {0, 1.5, EPointerSpace.PIXELS,
                'pixels y coordinate must be an integer; got 1.5'},
            {0, -1, EPointerSpace.PIXELS,
                'pixels y coordinate -1 is outside [0, 24]'},
            {0, 25, EPointerSpace.PIXELS,
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

    it('claims paired ownership once and returns defensive copies', function()
        local fixture = pointer_fixture()
        local adapter = fixture.adapter
        local first = paired_position(10, 11, 105, 92)

        assert.has_error(function() pointer_adapter.position(adapter) end,
            'mouse input requires a pointer position; call ' ..
            'ds.move_pointer() or subject:hover() first')
        pointer_adapter.set(adapter, first)
        first.grid.x = 99
        first.pixels.y = 999

        assert.is_true(pointer_adapter.is_active(adapter))
        assert.equals(1, cleanup.pending_count(fixture.registry))
        assert.same({10, 11}, {fixture.screen.getMousePos()})
        assert.same({105, 92}, {fixture.screen.getMousePixels()})
        assert.same({10, 11, 105, 92}, {
            fixture.gps.mouse_x,
            fixture.gps.mouse_y,
            fixture.gps.precise_mouse_x,
            fixture.gps.precise_mouse_y,
        })

        local returned = pointer_adapter.position(adapter)
        returned.grid.x = 77
        returned.pixels.y = 88
        assert.same(paired_position(10, 11, 105, 92),
            pointer_adapter.position(adapter))

        pointer_adapter.set(adapter, paired_position(12, 13, 125, 108))
        assert.equals(1, cleanup.pending_count(fixture.registry))
        assert.same({12, 13}, {fixture.screen.getMousePos()})
        assert.same({125, 108}, {fixture.screen.getMousePixels()})

        fixture.gps.mouse_x = 1
        fixture.gps.mouse_y = 2
        fixture.gps.precise_mouse_x = 3
        fixture.gps.precise_mouse_y = 4
        assert.same({12, 13}, {fixture.screen.getMousePos()})
        assert.same({12, 13, 125, 108}, {
            fixture.gps.mouse_x,
            fixture.gps.mouse_y,
            fixture.gps.precise_mouse_x,
            fixture.gps.precise_mouse_y,
        })
        fixture.gps.mouse_x = 1
        fixture.gps.mouse_y = 2
        fixture.gps.precise_mouse_x = 3
        fixture.gps.precise_mouse_y = 4
        assert.same({125, 108}, {fixture.screen.getMousePixels()})
        assert.same({12, 13, 125, 108}, {
            fixture.gps.mouse_x,
            fixture.gps.mouse_y,
            fixture.gps.precise_mouse_x,
            fixture.gps.precise_mouse_y,
        })
        fixture.gps.mouse_x = 1
        fixture.gps.mouse_y = 2
        fixture.gps.precise_mouse_x = 3
        fixture.gps.precise_mouse_y = 4
        local map_position, map_result = fixture.gui.getMousePos(true)
        assert.same({x=125, y=108, z=1}, map_position)
        assert.equals('map-result', map_result)
        assert.same({true}, fixture.gui_calls)
        assert.same({12, 13, 125, 108}, {
            fixture.gps.mouse_x,
            fixture.gps.mouse_y,
            fixture.gps.precise_mouse_x,
            fixture.gps.precise_mouse_y,
        })
        pointer_adapter.sync(adapter)
        assert.same({12, 13, 125, 108}, {
            fixture.gps.mouse_x,
            fixture.gps.mouse_y,
            fixture.gps.precise_mouse_x,
            fixture.gps.precise_mouse_y,
        })

        pointer_adapter.clear(adapter)
        assert.same({4, 5, 40, 50}, {
            fixture.gps.mouse_x,
            fixture.gps.mouse_y,
            fixture.gps.precise_mouse_x,
            fixture.gps.precise_mouse_y,
        })
        assert.equals(fixture.original_get_mouse_pos,
            fixture.screen.getMousePos)
        assert.equals(fixture.original_get_mouse_pixels,
            fixture.screen.getMousePixels)
        assert.equals(fixture.original_gui_get_mouse_pos,
            fixture.gui.getMousePos)
        assert.is_false(pointer_adapter.is_active(adapter))
        assert.is_nil(adapter.current_position)
        assert.is_nil(adapter.original_raw_position)
        assert.equals(0, cleanup.pending_count(fixture.registry))
    end)

    it('restores a transient pointer and native input state idempotently',
            function()
        local fixture = pointer_fixture()
        local restore = pointer_adapter.begin_transient(fixture.adapter)

        pointer_adapter.set_grid(fixture.adapter, 7, 8)
        fixture.enabler.mouse_focus = true
        fixture.enabler.tracking_on = 1
        fixture.enabler.mouse_lbut_down = 1
        assert.is_true(pointer_adapter.is_active(fixture.adapter))
        assert.same({7, 8, 75, 85}, {
            fixture.gps.mouse_x,
            fixture.gps.mouse_y,
            fixture.gps.precise_mouse_x,
            fixture.gps.precise_mouse_y,
        })

        restore()
        assert.is_false(pointer_adapter.is_active(fixture.adapter))
        assert.same({4, 5, 40, 50}, {
            fixture.gps.mouse_x,
            fixture.gps.mouse_y,
            fixture.gps.precise_mouse_x,
            fixture.gps.precise_mouse_y,
        })
        assert.is_false(fixture.enabler.mouse_focus)
        assert.equals(0, fixture.enabler.tracking_on)
        assert.equals(0, fixture.enabler.mouse_lbut_down)
        assert.equals(0, #fixture.registry.entries)

        restore()
        assert.same({4, 5, 40, 50}, {
            fixture.gps.mouse_x,
            fixture.gps.mouse_y,
            fixture.gps.precise_mouse_x,
            fixture.gps.precise_mouse_y,
        })
    end)

    it('preserves pre-existing pointer ownership after a transient move',
            function()
        local fixture = pointer_fixture()
        local initial = paired_position(10, 11, 105, 115)
        pointer_adapter.set(fixture.adapter, initial)
        local restore = pointer_adapter.begin_transient(fixture.adapter)

        pointer_adapter.set_grid(fixture.adapter, 7, 8)
        restore()

        assert.is_true(pointer_adapter.is_active(fixture.adapter))
        assert.same(initial, pointer_adapter.position(fixture.adapter))
        assert.same({10, 11, 105, 115}, {
            fixture.gps.mouse_x,
            fixture.gps.mouse_y,
            fixture.gps.precise_mouse_x,
            fixture.gps.precise_mouse_y,
        })
        assert.equals(1, #fixture.registry.entries)
    end)

    it('restores exact invalid raw sentinel coordinates during cleanup',
            function()
        local fixture = pointer_fixture({
            mouse_x=-1,
            mouse_y=-1,
            precise_mouse_x=-1,
            precise_mouse_y=-1,
        })
        pointer_adapter.set(fixture.adapter,
            paired_position(2, 3, 25, 28))

        local ok = cleanup.run(fixture.registry, 'sentinel restoration')

        assert.is_true(ok)
        assert.same({-1, -1, -1, -1}, {
            fixture.gps.mouse_x,
            fixture.gps.mouse_y,
            fixture.gps.precise_mouse_x,
            fixture.gps.precise_mouse_y,
        })
        assert.equals(fixture.original_get_mouse_pos,
            fixture.screen.getMousePos)
        assert.equals(fixture.original_get_mouse_pixels,
            fixture.screen.getMousePixels)
        assert.equals(fixture.original_gui_get_mouse_pos,
            fixture.gui.getMousePos)
        assert.is_false(pointer_adapter.is_active(fixture.adapter))
    end)

    it('preserves paired ownership across button transitions and failure',
            function()
        local fixture = pointer_fixture()
        local adapter = fixture.adapter
        pointer_adapter.set(adapter, paired_position(10, 11, 105, 92))

        local focus_ok, focus_error = pcall(function()
            pointer_adapter.with_mouse_focus(adapter, function()
                pointer_adapter.sync(adapter)
                assert.is_true(fixture.enabler.mouse_focus)
                assert.equals(1, fixture.enabler.tracking_on)
                error('focused operation failed', 0)
            end)
        end)
        assert.is_false(focus_ok)
        assert.matches('focused operation failed', focus_error, 1, true)
        assert.is_false(fixture.enabler.mouse_focus)
        assert.equals(0, fixture.enabler.tracking_on)

        local transition_ok, transition_error = pcall(function()
            pointer_adapter.with_button_state(adapter,
                'mouse_rbut_down', 'mouse_rbut_lift', true, function()
                    pointer_adapter.sync(adapter)
                    error('button transition failed', 0)
                end)
        end)
        assert.is_false(transition_ok)
        assert.matches('button transition failed', transition_error, 1, true)
        assert.equals(0, fixture.enabler.mouse_rbut_down)
        assert.equals(0, fixture.enabler.mouse_rbut_lift)
        assert.same({10, 11, 105, 92}, {
            fixture.gps.mouse_x,
            fixture.gps.mouse_y,
            fixture.gps.precise_mouse_x,
            fixture.gps.precise_mouse_y,
        })

        pointer_adapter.with_button_state(adapter,
            'mouse_lbut_down', 'mouse_lbut_lift', true, function()
                pointer_adapter.sync(adapter)
                assert.equals(1, fixture.enabler.mouse_lbut_down)
                assert.equals(0, fixture.enabler.mouse_lbut_lift)
            end)
        assert.equals(1, fixture.enabler.mouse_lbut_down)
        assert.equals(0, fixture.enabler.mouse_lbut_lift)
        assert.is_true(fixture.enabler.mouse_focus)
        assert.equals(1, fixture.enabler.tracking_on)

        pointer_adapter.with_button_state(adapter,
            'mouse_lbut_down', 'mouse_lbut_lift', false, function()
                pointer_adapter.sync(adapter)
                assert.equals(0, fixture.enabler.mouse_lbut_down)
                assert.equals(1, fixture.enabler.mouse_lbut_lift)
            end)
        assert.equals(0, fixture.enabler.mouse_lbut_down)
        assert.equals(0, fixture.enabler.mouse_lbut_lift)
        assert.is_false(fixture.enabler.mouse_focus)
        assert.equals(0, fixture.enabler.tracking_on)

        local names = {}
        for _, entry in ipairs(fixture.registry.entries) do
            table.insert(names, entry.name)
        end
        assert.same({'virtual pointer', 'mouse button state'}, names)
        local cleanup_ok = cleanup.run(
            fixture.registry, 'button state test')
        assert.is_true(cleanup_ok)
        assert.equals(0, fixture.enabler.mouse_lbut_down)
        assert.is_false(fixture.enabler.mouse_focus)
        assert.equals(0, fixture.enabler.tracking_on)
        assert.same({4, 5, 40, 50}, {
            fixture.gps.mouse_x,
            fixture.gps.mouse_y,
            fixture.gps.precise_mouse_x,
            fixture.gps.precise_mouse_y,
        })
        assert.equals(0, cleanup.pending_count(fixture.registry))
    end)

    it('restores independently across grid, pixel, and dual conflicts',
            function()
        local cases = {
            {grid=true, pixel=false},
            {grid=false, pixel=true},
            {grid=true, pixel=true},
        }
        for _, case in ipairs(cases) do
            local fixture = pointer_fixture()
            local external_grid = function() return 1, 2 end
            local external_pixels = function() return 3, 4 end
            pointer_adapter.set(fixture.adapter,
                paired_position(10, 11, 105, 92))
            if case.grid then
                fixture.screen.getMousePos = external_grid
            end
            if case.pixel then
                fixture.screen.getMousePixels = external_pixels
            end

            local ok, failures = cleanup.run(
                fixture.registry, 'accessor conflict')

            assert.is_false(ok)
            assert.equals(1, #failures)
            assert.same({4, 5, 40, 50}, {
                fixture.gps.mouse_x,
                fixture.gps.mouse_y,
                fixture.gps.precise_mouse_x,
                fixture.gps.precise_mouse_y,
            })
            assert.equals(
                case.grid and external_grid or
                    fixture.original_get_mouse_pos,
                fixture.screen.getMousePos)
            assert.equals(
                case.pixel and external_pixels or
                    fixture.original_get_mouse_pixels,
                fixture.screen.getMousePixels)
            assert.equals(case.grid,
                failures[1].message:find(
                    'getMousePos changed externally', 1, true) ~= nil)
            assert.equals(case.pixel,
                failures[1].message:find(
                    'getMousePixels changed externally', 1, true) ~= nil)
            assert.is_false(pointer_adapter.is_active(fixture.adapter))
            assert.is_nil(fixture.adapter.original_raw_position)
            assert.is_nil(fixture.adapter.original_get_mouse_pos)
            assert.is_nil(fixture.adapter.original_get_mouse_pixels)
            assert.is_nil(fixture.adapter.patched_get_mouse_pos)
            assert.is_nil(fixture.adapter.patched_get_mouse_pixels)
            assert.is_nil(fixture.adapter.cleanup_entry)
            assert.equals(0, cleanup.pending_count(fixture.registry))
        end
    end)

    it('continues cleanup after simultaneous accessor conflicts', function()
        local fixture = pointer_fixture()
        local earlier_cleanup_ran = false
        cleanup.push(fixture.registry, 'earlier resource', function()
            earlier_cleanup_ran = true
        end)
        pointer_adapter.set(fixture.adapter,
            paired_position(10, 11, 105, 92))
        local external_grid = function() return 1, 2 end
        local external_pixels = function() return 3, 4 end
        fixture.screen.getMousePos = external_grid
        fixture.screen.getMousePixels = external_pixels

        local ok, failures = cleanup.run(
            fixture.registry, 'continuation proof')

        assert.is_false(ok)
        assert.equals(1, #failures)
        assert.is_true(earlier_cleanup_ran)
        assert.equals(external_grid, fixture.screen.getMousePos)
        assert.equals(external_pixels, fixture.screen.getMousePixels)
        assert.same({4, 5, 40, 50}, {
            fixture.gps.mouse_x,
            fixture.gps.mouse_y,
            fixture.gps.precise_mouse_x,
            fixture.gps.precise_mouse_y,
        })
        assert.is_false(pointer_adapter.is_active(fixture.adapter))
        assert.equals(0, cleanup.pending_count(fixture.registry))
    end)

    it('preserves an external native map accessor during cleanup conflict',
            function()
        local fixture = pointer_fixture()
        local external_map = function() return {x=1, y=2, z=3} end
        pointer_adapter.set(fixture.adapter,
            paired_position(10, 11, 105, 92))
        fixture.gui.getMousePos = external_map

        local ok, failures = cleanup.run(
            fixture.registry, 'native map accessor conflict')

        assert.is_false(ok)
        assert.equals(1, #failures)
        assert.matches('dfhack.gui.getMousePos changed externally',
            failures[1].message, 1, true)
        assert.equals(external_map, fixture.gui.getMousePos)
        assert.equals(fixture.original_get_mouse_pos,
            fixture.screen.getMousePos)
        assert.equals(fixture.original_get_mouse_pixels,
            fixture.screen.getMousePixels)
        assert.same({4, 5, 40, 50}, {
            fixture.gps.mouse_x,
            fixture.gps.mouse_y,
            fixture.gps.precise_mouse_x,
            fixture.gps.precise_mouse_y,
        })
        assert.is_false(pointer_adapter.is_active(fixture.adapter))
        assert.is_nil(fixture.adapter.original_gui_get_mouse_pos)
        assert.is_nil(fixture.adapter.patched_gui_get_mouse_pos)
        assert.equals(0, cleanup.pending_count(fixture.registry))
    end)
end)
