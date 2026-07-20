-- Unit contracts for live interaction support utilities without DFHack state.

local cleanup = assert(loadfile(
    'tests/automation/support/cleanup.lua'))()
local diagnostics = assert(loadfile(
    'tests/automation/support/diagnostics.lua'))()
local fixture_loader = assert(loadfile(
    'tests/automation/support/fixture_loader.lua'))()
local pointer_adapter = assert(loadfile(
    'tests/automation/support/pointer_adapter.lua'))()

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
        rawset(_G, 'df', {global={gps={mouse_x=4, mouse_y=5}}})
    end)

    after_each(function()
        rawset(_G, 'dfhack', original_dfhack)
        rawset(_G, 'df', original_df)
    end)

    it('limits fixture names to the approved fixture registry', function()
        assert.is_true(fixture_loader.is_approved('interaction_screen'))
        assert.is_false(fixture_loader.is_approved('..\\outside'))
        assert.has_error(function()
            fixture_loader.load('.', '../outside')
        end, 'fixture name must be a relative identifier')
        assert.has_error(function()
            fixture_loader.load('.', 'outside')
        end, 'unknown automation fixture: outside')
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

    it('restores the virtual pointer and temporary native click position', function()
        local registry = cleanup.new({})
        local adapter = pointer_adapter.new(cleanup, registry)
        local original_pointer = dfhack.screen.getMousePos

        pointer_adapter.set(adapter, 10, 11)
        assert.same({10, 11}, {dfhack.screen.getMousePos()})
        local observed_x
        local observed_y
        pointer_adapter.with_interface_mouse(12, 13, function()
            observed_x = df.global.gps.mouse_x
            observed_y = df.global.gps.mouse_y
        end)
        assert.same({12, 13}, {observed_x, observed_y})
        assert.same({4, 5}, {df.global.gps.mouse_x, df.global.gps.mouse_y})

        pointer_adapter.clear(adapter)
        assert.equals(original_pointer, dfhack.screen.getMousePos)
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
