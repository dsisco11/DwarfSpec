local SearchRuntime = require('dwarfspec.driver.commands.search_runtime')

describe('search runtime capability', function()
    it('revalidates mount ownership and performs rendered matching', function()
        local subject = {control_path='root/label'}
        local target = {assert_current=function(_, operation)
            assert.equal('search', operation)
        end}
        local mount = {interaction_target=target, category='native'}
        local resolved = false
        local context = {
            subject_mounts={},
            is_subject=function(_, value) return value == subject end,
            require_current=function(_, operation)
                assert.equal('search', operation)
                return mount
            end,
            resolve_subject=function(_, value, operation)
                assert.equal(subject, value)
                assert.equal('search', operation)
                resolved = true
            end,
        }
        local runtime = SearchRuntime.new({mount_context=context,
            matcher=function(query, area)
                return {query=query, area=area}
            end})

        assert.is_true(runtime:is_subject(subject))
        assert.same({target_identity='root/label'},
            runtime:preflight(subject))
        assert.is_true(resolved)
        local area = {x1=1, y1=2, x2=3, y2=4}
        assert.same({query={text='needle', occurrence=1}, area=area},
            runtime:search({text='needle', occurrence=1}, area))
    end)
end)

describe('search runtime capability subject scope', function()
    it('retains subject-only empty-scope rejection across command boundaries',
            function()
        local TextSearch = require('dwarfspec.driver.commands.text_search')
        local mount = {category='native', interaction_target={
            assert_current=function() end}}
        local context = {subject_mounts={},
            is_subject=function() return false end,
            require_current=function() return mount end,
            resolve_subject=function() end}
        local runtime = SearchRuntime.new({mount_context=context,
            matcher=function() return TextSearch.EMPTY_INTERSECTION end})
        assert.has_error(function()
            runtime:search({text='needle'}, {x1=90, y1=30, x2=95, y2=35},
                true)
        end, 'DwarfSpec search subject has no usable visible body bounds ' ..
            'within the current window')
    end)
end)
