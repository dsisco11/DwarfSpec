local command = require('dwarfspec.driver.commands.input')

describe('input command binding', function()
    it('keeps keyboard and text entry as distinct commands', function()
        local dispatched = {}
        local commands = command.new({
            context={mount_context={mutate=function(_, _, action) return action() end}},
            resolve_target=function() return nil, {} end,
            simulate_input=function(_, _, key) table.insert(dispatched, key) end,
        })
        commands.input('SELECT')
        commands.type('ab')
        assert.same({'SELECT', 'STRING_A097', 'STRING_A098'}, dispatched)
    end)
end)
