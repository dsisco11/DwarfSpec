-- Live producer for post-teardown file-suite focus pollution.

local fixture = require(
    'tests.automation.support.base_screen_focus_pollution')
fixture.bind(ds, assert)

describe('suite base-screen focus pollution producer', function()
    teardown(function()
        fixture.open_hauling()
    end)

    it('01 inherits the original restored focus from the preceding file',
            function()
        local state = fixture.state()
        assert.equals(
            state.original_screen, dfhack.gui.getDFViewscreen(true))
        assert.same(
            state.original_focus,
            dfhack.gui.getFocusStrings(state.original_screen))
    end)

    describe('02 nested context', function()
        it('does not create a distinct file-suite lifecycle', function()
            local suite_changes = fixture.change_events(
                function(content)
                    return content.scope == 'suite'
                end)
            assert.same({}, suite_changes)
        end)
    end)
end)
