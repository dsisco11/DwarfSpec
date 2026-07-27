-- Unit contracts for shared live command-conformance support.

local conformance = assert(loadfile(
    'tests/automation/support/command_conformance.lua'))()

---Returns one complete supported-host capability declaration.
---@return table
local function capabilities()
    return {
        root_inspection=true,
        tree_capture=true,
        screen_capture=true,
        subject_pointer_placement=true,
        subject_hover=true,
        keyboard_input=true,
        text_input=true,
        physical_mouse_states=true,
        default_wait_redraw=true,
        no_wait_redraw=true,
        viewport='supported',
    }
end

describe('command conformance support', function()
    it('rejects unknown, incomplete, and contradictory capabilities',
            function()
        local unknown = capabilities()
        unknown.teleport=true
        assert.has_error(function()
            conformance.new(unknown)
        end, 'unknown command conformance capability: teleport')

        local incomplete = capabilities()
        incomplete.tree_capture=nil
        assert.has_error(function()
            conformance.new(incomplete)
        end, 'command conformance capability tree_capture must be boolean; ' ..
            'got nil')

        local contradictory = capabilities()
        contradictory.subject_pointer_placement=false
        assert.has_error(function()
            conformance.new(contradictory)
        end, 'subject_hover requires subject_pointer_placement')

        local redraw = capabilities()
        redraw.default_wait_redraw=false
        assert.has_error(function()
            conformance.new(redraw)
        end, 'no_wait_redraw requires default_wait_redraw')

        local viewport = capabilities()
        viewport.viewport=true
        assert.has_error(function()
            conformance.new(viewport)
        end, 'command conformance capability viewport must be "supported" ' ..
            'or "rejected"; got true')
    end)

    it('runs all cleanup after success and leaves no owned state', function()
        local helper = conformance.new(capabilities())
        local cleaned = {}

        helper:run(function(fixture)
            fixture:defer('first', function()
                table.insert(cleaned, 'first')
            end)
            fixture:defer('second', function()
                table.insert(cleaned, 'second')
            end)
        end)

        assert.same({'second', 'first'}, cleaned)
        helper:assert_clean()
    end)

    it('runs all cleanup after injected body and cleanup failures', function()
        local helper = conformance.new(capabilities())
        local final_cleanup_ran = false

        local ok, failure = pcall(function()
            helper:run(function(fixture)
                fixture:defer('final cleanup', function()
                    final_cleanup_ran = true
                end)
                fixture:defer('injected cleanup', function()
                    error('cleanup exploded', 0)
                end)
                error('body exploded', 0)
            end)
        end)

        assert.is_false(ok)
        assert.matches('body exploded', failure, 1, true)
        assert.matches('cleanup also failed', failure, 1, true)
        assert.matches('cleanup exploded', failure, 1, true)
        assert.is_true(final_cleanup_ran)
        helper:assert_clean()
    end)

    it('detects pending fixture ownership', function()
        local helper = conformance.new(capabilities())
        helper:defer('still owned', function() end)

        assert.has_error(function()
            helper:assert_clean()
        end, 'command conformance fixture retains 1 cleanup action(s)')
        assert.is_true(helper:cleanup())
        helper:assert_clean()
    end)

    it('asserts redraw timing and bounded captures', function()
        local generation = 0

        conformance.assert_default_wait_redraw(function()
            return generation
        end, function()
            generation = generation + 1
        end)
        conformance.assert_no_wait_redraw(function()
            return generation
        end, function()
        end, function(before)
            assert.equals(before, generation)
            generation = generation + 1
        end)

        conformance.assert_bounded_screen({
            width=2,
            height=1,
            cells={{{ch=65}, {ch=66}}},
        }, 2, 1)
        conformance.assert_bounded_tree({
            view_id='root',
            children={{view_id='child', children={}}},
        }, 'root', 2, 1)
    end)

    it('owns counters and compares exact pointer snapshots', function()
        local helper = conformance.new(capabilities())
        local observe, read = helper:counter('input')
        local environment = {
            screen={
                getMousePos=function() return 1, 2 end,
                getMousePixels=function() return 10, 20 end,
            },
            gps={
                mouse_x=1,
                mouse_y=2,
                precise_mouse_x=10,
                precise_mouse_y=20,
            },
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
        }
        local snapshot = conformance.pointer_snapshot(environment)

        assert.equals(1, observe())
        assert.equals(3, observe(2))
        assert.equals(3, read())
        conformance.assert_pointer_restored(
            snapshot, conformance.pointer_snapshot(environment))

        environment.enabler.mouse_lbut_down = 1
        assert.has_error(function()
            conformance.assert_pointer_restored(
                snapshot, conformance.pointer_snapshot(environment))
        end, 'pointer state field mouse_lbut_down changed: expected 0, got 1')
    end)
end)
