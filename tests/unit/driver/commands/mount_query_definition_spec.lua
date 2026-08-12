local CommandKind = require('dwarfspec.protocol.enums.command_kinds')
local MountQueries = require(
    'dwarfspec.driver.commands.mount_query_definition')
local TestRunner = dofile(
    'tests/unit/driver/commands/definition_test_support.lua')

describe('verified mount query definitions', function()
    it('owns root, get, inspect, and tree capture bindings', function()
        local runner, ds = TestRunner.new(), {}
        local operations = {preflight=function() return true end,
            root=function() return 'root' end,
            get=function() return 'get' end,
            inspect=function() return 'inspect' end,
            capture_view_tree=function() return 'tree' end}
        MountQueries.bind(ds, runner, operations)
        local options = {timeout_ms=10}
        assert.equals('root', ds.root(nil, options))
        assert.equals('get', ds.get('child', nil, options))
        assert.equals('inspect', ds.inspect({}, options))
        assert.equals('capture_view_tree',
            ds.capture_view_tree('tree', nil, options))
        assert.same({'capture_view_tree', 'get', 'inspect', 'root'},
            runner:names())
        for _, name in ipairs(runner:names()) do
            assert.equals(CommandKind.QUERY, runner:definition(name).kind)
        end
    end)
end)
