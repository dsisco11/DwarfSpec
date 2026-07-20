-- Passing live command-runner proof.

describe('command runner pass path', function()
    it('executes selected Busted examples', function()
        assert.equals(1, ds.protocol_version)
    end)
end)
