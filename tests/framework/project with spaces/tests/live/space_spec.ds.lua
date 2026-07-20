-- Live proof that consumer project paths may contain spaces.

describe('project path with spaces', function()
    it('runs without shell tokenization', function()
        assert.equals(1, ds.protocol_version)
    end)
end)
