local Immutable = require('dwarfspec.support.immutable')

describe('immutable table support', function()
    it('creates shallow read-only views with table behavior', function()
        local source = {10, 20, name='before'}
        local view = Immutable.read_only(source, 'sample')
        assert.equals(10, view[1])
        assert.equals(2, #view)
        local seen = {}
        for key, value in pairs(view) do seen[key] = value end
        assert.same({10, 20, name='before'}, seen)
        assert.is_false(getmetatable(view))
        assert.has_error(function() view.name = 'after' end,
            'sample is immutable')
        source.name = 'after'
        assert.equals('after', view.name)
    end)

    it('recursively detaches keys and values into immutable snapshots', function()
        local key = {id='key'}
        local nested = {value='before'}
        local source = {[key]=nested, nested=nested, 1, 2}
        local frozen = Immutable.freeze(source, 'snapshot')
        source[1] = 9
        nested.value = 'after'
        key.id = 'changed'
        assert.equals(1, frozen[1])
        assert.equals(2, #frozen)
        assert.equals('before', frozen.nested.value)
        local frozen_key, frozen_value
        for candidate, value in pairs(frozen) do
            if type(candidate) == 'table' then
                frozen_key, frozen_value = candidate, value
            end
        end
        assert.equals('key', frozen_key.id)
        assert.equals('before', frozen_value.value)
        assert.has_error(function() frozen.nested.value = 'no' end,
            'snapshot is immutable')
        assert.has_error(function() frozen_key.id = 'no' end,
            'snapshot is immutable')
        assert.is_false(getmetatable(frozen))
    end)

    it('rejects cycles with the supplied deterministic label', function()
        local cyclic = {}
        cyclic.self = cyclic
        assert.has_error(function() Immutable.freeze(cyclic, 'graph') end,
            'graph must be acyclic')
    end)

    it('preserves only values selected by the preservation hook', function()
        local token = {identity='token'}
        local ordinary = {identity='copy'}
        local frozen = Immutable.freeze({[token]='key', token=token,
            ordinary=ordinary, callback=math.abs, scalar=42},
            'snapshot', function(value) return value == token end)
        assert.is_true(frozen.token == token)
        assert.equals('key', frozen[token])
        assert.is_false(frozen.ordinary == ordinary)
        assert.is_true(frozen.callback == math.abs)
        assert.equals(42, frozen.scalar)
        ordinary.identity = 'changed'
        assert.equals('copy', frozen.ordinary.identity)
    end)
end)
