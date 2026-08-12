local CommandKind = require('dwarfspec.protocol.enums.command_kinds')
local WaitDefinitions = require(
    'dwarfspec.driver.commands.wait_definition')
local TestRunner = dofile(
    'tests/unit/driver/commands/definition_test_support.lua')

describe('verified wait assertion definitions', function()
    ---Creates deterministic wait operations for definition tests.
    ---@return table<string, function>
    local function operations()
        return {wait_frames=function(count) return count end,
            wait_ticks=function(count) return count end,
            wait_event=function(event) return {event=event} end,
            wait_until=function(_, query) return query() end}
    end

    it('owns all public wait bindings and trailing command options', function()
        local runner, ds = TestRunner.new(), {}
        WaitDefinitions.bind(ds, runner, operations())
        local options = {timeout_ms=20}
        assert.equals('wait_frames', ds.wait_frames(2, {description='frames'},
            options))
        assert.equals('wait_ticks', ds.wait_ticks(3, nil, options))
        assert.equals('await', ds.await('ready', function() return true end,
            nil, options))
        assert.equals('awaitEvent', ds.awaitEvent('MAP_LOADED', nil, options))
        assert.same({'await', 'awaitEvent', 'wait_frames', 'wait_ticks'},
            runner:names())
        for _, name in ipairs(runner:names()) do
            assert.equals(CommandKind.ASSERTION, runner:definition(name).kind)
        end
        assert.equals(options, runner:invocations()[1].options)
    end)

    it('uses explicit pending and ready observations under one deadline',
            function()
        local calls = 0
        local wait_operations = operations()
        wait_operations.wait_until = function(_, query)
            calls = calls + 1
            if calls == 1 then
                return require('dwarfspec.driver.command.outcomes').pending(
                    'eventual is pending', {armed=true})
            end
            return query()
        end
        local definitions = WaitDefinitions.new(wait_operations):definitions()
        local by_name = {}
        for _, definition in ipairs(definitions) do by_name[definition.name] = definition end
        local request = by_name.await.normalize({
            description='eventual', query=function() return 'ready' end})
        local context = {
            remaining_ms=function() return 10 end,
        }
        local pending = by_name.await.execute(context, request)
        assert.equals('pending', pending.kind)
        local outcome = by_name.await.execute(context, request)
        assert.equals('ready', outcome.kind)
        assert.equals('ready', outcome.value)
        assert.equals(2, calls)
        assert.same({armed=true}, pending.evidence)
    end)

    it('preserves explicit fatal observations and thrown timeouts', function()
        local Outcomes = require('dwarfspec.driver.command.outcomes')
        local definitions = WaitDefinitions.new({
            wait_frames=function() return Outcomes.fatal('scheduler failed') end,
            wait_ticks=function() end,
            wait_event=function() end,
            wait_until=function() end,
        }):definitions()
        local definition
        for _, candidate in ipairs(definitions) do
            if candidate.name == 'wait_frames' then definition = candidate end
        end
        local request = definition.normalize({count=1})
        local context = {remaining_ms=function() return 10 end}
        local fatal = definition.execute(context, request)
        assert.equals('fatal', fatal.kind)
        assert.is_truthy(fatal.message:find('scheduler failed', 1, true))

        definitions = WaitDefinitions.new({
            wait_frames=function() error('command deadline expired') end,
            wait_ticks=function() end,
            wait_event=function() end,
            wait_until=function() end,
        }):definitions()
        assert.has_error(function()
            definitions[1].execute(context,
                definitions[1].normalize({count=1}))
        end, 'command deadline expired')
    end)

    it('preserves ordinary table results that contain a kind field', function()
        local definitions = WaitDefinitions.new(operations()):definitions()
        local definition
        for _, candidate in ipairs(definitions) do
            if candidate.name == 'await' then definition = candidate end
        end
        local value = {kind='widget', id=1}
        local request = definition.normalize({
            description='table observation', query=function() return value end,
        })
        local outcome = definition.execute({
            remaining_ms=function() return 10 end,
        }, request)
        assert.equals('ready', outcome.kind)
        assert.equals(value, outcome.value)
    end)

    it('maps legacy positive timeouts behind trailing command options',
            function()
        local runner, ds = TestRunner.new(), {}
        WaitDefinitions.bind(ds, runner, operations())
        ds.wait_frames(1, {timeout_ms=25})
        assert.equals(25, runner:invocations()[1].options.timeout_ms)

        ds.wait_frames(1, {timeout_ms=25}, {timeout_ms=50})
        assert.equals(50, runner:invocations()[2].options.timeout_ms)
        local definition = WaitDefinitions.new(operations()):definitions()[1]
        assert.has_error(function()
            definition.normalize({count=1,
                options={timeout_ms='invalid'}})
        end, 'wait timeout must be false or a positive finite integer')

        local await_event = WaitDefinitions.new(operations()):definitions()[4]
        assert.has_error(function()
            await_event.normalize({event='MAP_LOADED',
                options={timeout_ms='invalid'}})
        end, 'wait timeout must be false or a positive finite integer')

        assert.has_error(function()
            ds.awaitEvent('MAP_LOADED', {timeout_ms=1.5}, {timeout_ms=50})
        end, 'wait timeout must be false or a positive finite integer')
        assert.has_error(function()
            ds.wait_frames(1, {timeout_ms=1.5}, {timeout_ms=50})
        end, 'wait timeout must be false or a positive finite integer')
    end)
end)
