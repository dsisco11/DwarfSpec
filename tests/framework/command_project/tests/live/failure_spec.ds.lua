-- Deliberate assertion failure used to prove external exit propagation.

describe('command runner failure path', function()
    it('reports deliberate assertion failures', function()
        assert.equals('expected', 'deliberate failure')
    end)
end)
