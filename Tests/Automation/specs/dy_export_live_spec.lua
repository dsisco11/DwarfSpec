-- Isolated Busted environment proof for the dy interaction namespace.

describe('automation helper export', function()
    it('exposes dy without changing the process global table', function()
        assert.is_nil(rawget(_G, 'dy'))
        assert.equals(1, dy.protocol_version)
    end)
end)
