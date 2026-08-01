-- Unit contracts for bounded non-serializing diagnostic identities.

local identity_labels = require('dwarfspec.support.identity_labels')

describe('DwarfSpec diagnostic identity labels', function()
    it('uses stable opaque labels without invoking compound serialization',
            function()
        local first = setmetatable({}, {
            __tostring=function()
                error('compound serialization must not run', 0)
            end,
        })
        local second = {}

        local first_label = identity_labels.of(first)

        assert.matches('^table#%d+$', first_label)
        assert.equals(first_label, identity_labels.of(first))
        assert.matches('^table#%d+$', identity_labels.of(second))
        assert.not_equals(first_label, identity_labels.of(second))
    end)

    it('bounds scalar identity labels', function()
        local label = identity_labels.of(string.rep('x', 200))

        assert.equals(87, #label)
        assert.matches('%.%.%.$', label)
        assert.equals('<nil>', identity_labels.of(nil))
    end)
end)
