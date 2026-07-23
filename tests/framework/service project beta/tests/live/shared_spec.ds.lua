-- Space-containing multi-project fixture with a deliberately shared identity.

describe('service project beta', function()
    it('retains beta ownership', function()
        assert.equals('beta', 'beta')
    end)
end)
