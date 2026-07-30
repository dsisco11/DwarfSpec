-- Live observer and restorer for file-suite focus pollution.

local fixture = require(
    'tests.automation.support.base_screen_focus_pollution')
fixture.bind(ds, assert)

describe('suite base-screen focus pollution observer and restorer',
        function()
    teardown(function()
        fixture.restore_original()
        fixture.clear_state()
    end)

    it('01 observes exactly the producer suite warning', function()
        local suite_changes = fixture.change_events(
            function(content)
                return content.scope == 'suite'
            end)
        assert.equals(1, #suite_changes)
        fixture.assert_focus_change(suite_changes[1], {
            scope='suite',
            attribution='file',
            suite_name=fixture.PRODUCER_SUITE,
        })
        assert.is_true(dfhack.gui.matchFocusString(
            'dwarfmode/Hauling', fixture.state().original_screen))
    end)

    describe('02 nested observer context', function()
        it('still sees only the producer file-suite warning', function()
            local suite_changes = fixture.change_events(
                function(content)
                    return content.scope == 'suite'
                end)
            assert.equals(1, #suite_changes)
            assert.equals(
                fixture.PRODUCER_SUITE,
                suite_changes[1].payload.content.suite_name)
        end)
    end)
end)
