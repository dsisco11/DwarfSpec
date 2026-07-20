-- Product-independent live proof for the DwarfSpec consumer boundary.

describe('minimal DwarfSpec consumer', function()
    it('uses isolated commands, diagnostics, and explicit fixture imports',
            function()
        assert.is_nil(rawget(_G, 'ds'))
        assert.equals('minimal-consumer', ds.consumer_identity())

        local colocated = ds.show_fixture(
            'tests/live/fixtures/cover.fixture.lua')
        assert.is_true(ds.diagnostic('render_generation', colocated) >= 1)
        ds.dismiss(colocated)

        local external = ds.show_fixture('tests/support/external_screen.lua')
        assert.is_true(ds.diagnostic('render_generation', external) >= 1)
        ds.dismiss(external)
    end)
end)
