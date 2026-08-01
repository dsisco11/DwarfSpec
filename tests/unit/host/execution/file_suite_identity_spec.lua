-- Unit contracts for DwarfSpec-owned file-suite identities.

local FileSuiteIdentity =
    require('dwarfspec.host.execution.file_suite_identity')

---Creates one representative file-suite identity.
---@return DwarfSpecFileSuiteIdentity
local function identity()
    return FileSuiteIdentity.new({
        suite_id='tests/example_spec.lua#repeat=1#instance=1',
        suite_name='tests/example_spec.lua',
        source_identity='tests/example_spec.lua',
        repeat_index=1,
        repeat_count=2,
    })
end

describe('file-suite identity', function()
    it('constructs an identity with its copy method', function()
        local value = identity()

        assert.equals(
            'tests/example_spec.lua#repeat=1#instance=1', value.suite_id)
        assert.equals('tests/example_spec.lua', value.suite_name)
        assert.equals('tests/example_spec.lua', value.source_identity)
        assert.equals(1, value.repeat_index)
        assert.equals(2, value.repeat_count)
        assert.is_function(value.copy)
    end)

    it('returns an independently mutable identity copy', function()
        local original = identity()
        local copied = original:copy()

        assert.not_equals(original, copied)
        assert.same(original, copied)
        copied.suite_name = 'tests/changed_spec.lua'
        assert.equals('tests/example_spec.lua', original.suite_name)
        assert.equals('tests/changed_spec.lua', copied.suite_name)
        assert.is_function(copied.copy)
    end)

    it('rejects incomplete and invalid identity fields', function()
        assert.has_error(function()
            FileSuiteIdentity.new({})
        end, 'file-suite identity suite_id must be a nonempty string')
        assert.has_error(function()
            FileSuiteIdentity.new({
                suite_id='suite',
                suite_name='suite',
                source_identity='suite',
                repeat_index=0,
                repeat_count=1,
            })
        end,
            'file-suite identity repeat_index must be a positive integer')
    end)
end)
