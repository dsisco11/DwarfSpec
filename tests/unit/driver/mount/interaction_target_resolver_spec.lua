local Resolver = require(
    'dwarfspec.driver.mount.interaction_target_resolver')

describe('interaction target resolver', function()
    it('resolves roots and current-run subjects through one mount context', function()
        local target = {}
        local root = {}
        local adapter = {root=function() return root end}
        local mount = {interaction_target=target,
            subject_source={adapter=adapter}}
        local subject_adapter = {}
        local subject = {control_path='root/child',
            _descriptor={adapter=subject_adapter}}
        local context = {current=mount,
            require_current=function() return mount end,
            is_subject=function(_, value) return value == subject end,
            resolve_subject=function(_, value) return value.resolved end}
        subject.resolved = {}
        local resolver = Resolver.new(context)

        assert.same({root, target, mount, adapter},
            {resolver:resolve(nil, 'inspect')})
        assert.same({subject.resolved, target, mount, subject_adapter},
            {resolver:resolve(subject, 'click')})
    end)

    it('rejects values outside the current run subject capability', function()
        local context = {require_current=function() return {} end,
            is_subject=function() return false end,
            resolve_subject=function() end}
        local resolver = Resolver.new(context)
        assert.has_error(function() resolver:resolve({}, 'click') end,
            'DwarfSpec click requires a subject from the current mount; ' ..
                'use ds.get(control_path) or ds.root()')
    end)
end)
