-- Multi-project fixture with an identity intentionally shared by another root.

describe('service project alpha', function()
    it('retains alpha ownership', function()
        assert.equals('alpha', 'alpha')
    end)
end)
