-- Unit contracts for the live automation cleanup registry.

local cleanup = assert(loadfile(
    'tests/automation/support/cleanup.lua'))()

describe('automation cleanup registry', function()
    it('runs actions once in strict LIFO order across repeated resets', function()
        local registry = cleanup.new({})
        local order = {}
        cleanup.push(registry, 'first', function()
            table.insert(order, 'first')
        end)
        cleanup.push(registry, 'second', function()
            table.insert(order, 'second')
        end)

        local first_ok = cleanup.run(registry, 'first reset')
        local second_ok = cleanup.run(registry, 'second reset')

        assert.is_true(first_ok)
        assert.is_true(second_ok)
        assert.same({'second', 'first'}, order)
        assert.equals(0, cleanup.pending_count(registry))
        assert.equals(2, registry.reset_count)
    end)

    it('continues cleanup after an action fails', function()
        local registry = cleanup.new({})
        local restored = false
        cleanup.push(registry, 'restoration', function()
            restored = true
        end)
        cleanup.push(registry, 'broken action', function()
            error('deliberate cleanup failure')
        end)

        local ok, failures = cleanup.run(registry, 'failure proof')

        assert.is_false(ok)
        assert.is_true(restored)
        assert.equals(1, #failures)
        assert.equals('broken action', failures[1].name)
        assert.matches('deliberate cleanup failure', failures[1].message,
            1, true)
        assert.equals(0, cleanup.pending_count(registry))
    end)

    it('releases an owned action without executing it', function()
        local registry = cleanup.new({})
        local called = false
        local entry = cleanup.push(registry, 'released action', function()
            called = true
        end)

        assert.is_true(cleanup.release(registry, entry))
        assert.is_false(cleanup.release(registry, entry))
        assert.is_true(cleanup.run(registry, 'release proof'))
        assert.is_false(called)
    end)

    it('rejects release through a different registry', function()
        local owner = cleanup.new({})
        local other = cleanup.new({})
        local entry = cleanup.push(owner, 'owned action', function() end)

        assert.has_error(function()
            cleanup.release(other, entry)
        end, 'cleanup action belongs to a different registry')
        assert.equals(1, cleanup.pending_count(owner))
        assert.is_true(cleanup.run(owner, 'ownership proof'))
    end)

    it('drains only entries newer than a scoped marker', function()
        local registry = cleanup.new({})
        local order = {}
        cleanup.push(registry, 'run baseline', function()
            table.insert(order, 'baseline')
        end)
        local marker = cleanup.mark(registry)
        cleanup.push(registry, 'mount parent', function()
            table.insert(order, 'parent')
        end)
        cleanup.push(registry, 'mount child', function()
            table.insert(order, 'child')
        end)

        assert.is_true(cleanup.run_from(registry, marker, 'mount cleanup'))
        assert.same({'child', 'parent'}, order)
        assert.equals(1, cleanup.pending_count(registry))
        assert.is_true(cleanup.run(registry, 'run cleanup'))
        assert.same({'child', 'parent', 'baseline'}, order)
    end)
end)
