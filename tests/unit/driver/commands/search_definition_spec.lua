local CommandKind = require('dwarfspec.protocol.enums.command_kinds')
local Harness = dofile('tests/unit/driver/command/engine_harness.lua')
local SearchDefinition = require('dwarfspec.driver.builtins.search')
local SearchRuntime = require('dwarfspec.driver.commands.search_runtime')
local TestRunner = dofile(
    'tests/unit/driver/commands/definition_test_support.lua')
local BuiltinSupport = dofile(
    'tests/unit/driver/commands/builtin_test_support.lua')

---@class dwarfspec.tests.SearchDefinitionDependencies
local Dependencies = {}

---Creates isolated search-definition dependencies.
---@param result? any
---@return table
function Dependencies.new(result)
    local mount = {category='native',
        interaction_target={assert_current=function() end}}
    local mount_context = {
        subject_mounts={},
        is_subject=function(_, value) return value == 'subject' end,
        require_current=function() return mount end,
        resolve_subject=function(_, subject) return subject end,
    }
    return SearchRuntime.new({mount_context=mount_context,
        matcher=function() return result end})
end

describe('verified search command definition', function()
    it('owns registration and public query binding', function()
        local runner, ds = BuiltinSupport.register({
            SearchDefinition.new(Dependencies.new())})
        local options = {timeout_ms=10}
        local query = {text='visible'}
        assert.equals('search', ds.search(query, 'subject', options))
        assert.same({'search'}, runner:names())
        local invocation = runner:invocations()[1]
        assert.equals(query, invocation.arguments.query)
        assert.is_true(invocation.arguments.search_area_is_subject)
        assert.equals(options, invocation.options)
        assert.equals(CommandKind.QUERY,
            runner:definition('search').kind)
    end)

    it('distinguishes a successful nil observation from pending', function()
        local harness = Harness.new()
        local definition = SearchDefinition.new(Dependencies.new()):definition()
        harness:register(TestRunner.fixture(definition))
        assert.is_nil(harness:invoke('search', {query={text='missing'}}))
    end)

    it('projects a plain observation into caller verification', function()
        local harness = Harness.new()
        local rectangle = {x1=1, y1=2, x2=3, y2=4}
        local definition = SearchDefinition.new(
            Dependencies.new(rectangle)):definition()
        harness:register(TestRunner.fixture(definition))
        assert.same(rectangle, harness:invoke('search', {
            query={text='visible'}}, {
            verify=function(observation)
                return observation.public_result.x1 == 1 and
                    observation.public_result.y2 == 4
            end}))
    end)

    it('rejects the former loose callback bundle', function()
        assert.has_error(function()
            SearchDefinition.new({is_subject=function() end,
                preflight=function() end, search='not a method'})
        end, 'search command runtime requires search')
    end)
end)
