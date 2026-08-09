-- Public namespace contracts for definition-only project command dispatch.

local DS = require('dwarfspec.ds')

describe('DwarfSpec verified project command binding', function()
    it('registers definitions and routes every call through the runner', function()
        local namespace = {}
        local definition = {name='project_query'}
        local registered
        local invoked
        local runner = {
            registerProject=function(_, value, source)
                registered = {definition=value, source=source}
            end,
            invoke=function(_, name, arguments, options)
                invoked = {name=name, arguments=arguments, options=options}
                return 'verified result'
            end,
        }

        DS.bind_project_commands(namespace, {
            project_query={definition=definition,
                source='tests/dwarfspec/commands.lua'},
        }, runner)
        local arguments = {value=7}
        local options = {timeout_ms=20}
        assert.equals('verified result',
            namespace.project_query(arguments, options))

        assert.equals(definition, registered.definition)
        assert.equals('tests/dwarfspec/commands.lua', registered.source)
        assert.same({name='project_query', arguments=arguments,
            options=options}, invoked)
    end)

    it('rejects any runtime without definition registration authority', function()
        assert.has_error(function()
            DS.bind_project_commands({}, {}, {invoke=function() end})
        end, 'project command binding requires the verified runner')
    end)
end)
