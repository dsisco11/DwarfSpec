local command = require('dwarfspec.driver.commands.mount')

describe('mount command binding', function()
    it('preserves the supplied mount command behavior', function()
        local mounted
        local commands = command.new({
            context={mount_context={mount=function(_, component)
                mounted = component
                return 'mounted:' .. component
            end}},
        })
        assert.equals('mounted:screen', commands.mount('screen'))
        assert.equals('screen', mounted)
    end)

    it('rejects a third argument on ordinary class mounts', function()
        local commands = command.new({context={mount_context={
            boundary={classify=function() return {input_form='class'} end},
            mount=function() return true end,
        }}})
        assert.has_error(function() commands.mount({}, nil, {}) end,
            'DwarfSpec class mount does not accept a third argument')
    end)

    it('rejects instantiated components before delegating to mount ownership', function()
        local calls = 0
        local commands = command.new({context={mount_context={
            boundary={classify=function() return {input_form='instance'} end},
            mount=function() calls = calls + 1 end,
        }}})
        assert.has_error(function() commands.mount({}) end,
            'DwarfSpec ds.mount() accepts a component class, not an instance')
        assert.equals(0, calls)
    end)
end)
