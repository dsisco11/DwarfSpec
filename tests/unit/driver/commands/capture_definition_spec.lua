local CommandKind = require('dwarfspec.protocol.enums.command_kinds')
local CaptureDefinition = require(
    'dwarfspec.driver.commands.capture_definition')
local TestRunner = dofile(
    'tests/unit/driver/commands/definition_test_support.lua')

describe('verified screen capture query definition', function()
    it('owns capture binding and preserves opaque capture options', function()
        local runner, ds = TestRunner.new(), {}
        CaptureDefinition.bind(ds, runner, function() return {} end)
        local capture_options = {adapter={}}
        local command_options = {timeout_ms=10}
        assert.equals('capture_screen', ds.capture_screen('screen',
            capture_options, command_options))
        assert.equals(CommandKind.QUERY,
            runner:definition('capture_screen').kind)
        assert.equals(capture_options,
            runner:invocations()[1].arguments.options)
        assert.equals(command_options, runner:invocations()[1].options)
    end)
end)
