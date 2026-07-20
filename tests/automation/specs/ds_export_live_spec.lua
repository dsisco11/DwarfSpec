-- Isolated Busted environment proof for the ds interaction namespace.

describe('automation helper export', function()
    it('exposes ds without changing the process global table', function()
        assert.is_nil(rawget(_G, 'ds'))
        assert.is_nil(rawget(_G, 'dy'))
        assert.equals(1, ds.protocol_version)
        assert.is_function(ds.await)
        assert.is_function(ds.input)
        assert.is_function(ds.move_pointer)
        assert.is_nil(ds.wait_until)
    end)
end)
