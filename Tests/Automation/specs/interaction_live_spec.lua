-- Live contracts for generic fixture, inspection, pointer, input, and capture APIs.

describe('automation live interactions', function()
    local screen
    local initial_pause_state

    before_each(function()
        initial_pause_state = df.global.pause_state
        screen = ds.show_fixture('interaction_screen')
    end)

    it('shows, finds, inspects, hovers, clicks, types, captures, and dismisses',
            function()
        local target = ds.get(screen, 'tooltip_target')
        local input = ds.get(screen, 'input_echo')
        local initial_pointer_function = dfhack.screen.getMousePos

        local inspection = ds.inspect(target)
        local tree = ds.capture_view_tree(screen, 'interaction-tree')
        assert.equals('tooltip_target', inspection.view_id)
        assert.is_true(inspection.visible)
        assert.is_truthy(inspection.body)
        assert.equals('fixture_root', tree.children[1].view_id)
        assert.equals(0, screen.click_count)

        ds.move_pointer_to(target)
        ds.wait_for_render(screen)
        assert.matches('^Automation hover %d+,%d+$', target.tooltip)

        ds.click(target)
        assert.equals(1, screen.click_count)
        ds.type('Hi', screen)
        assert.equals('Hi', screen.typed_text)
        assert.equals('Typed: Hi', input.text)
        ds.press('CUSTOM_A', screen)
        assert.equals('CUSTOM_A', screen.last_key)

        local capture = ds.capture_screen('interaction-cells', {
            max_width=8,
            max_height=4,
        })
        assert.equals(8, capture.width)
        assert.equals(4, capture.height)
        assert.equals(4, #capture.cells)

        ds.clear_pointer()
        assert.equals(initial_pointer_function, dfhack.screen.getMousePos)
        ds.dismiss(screen)
        assert.is_false(screen:isActive())
        ds.reset()
        assert.equals(initial_pause_state, df.global.pause_state)
    end)
end)
