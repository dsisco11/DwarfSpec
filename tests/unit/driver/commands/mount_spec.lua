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
end)
