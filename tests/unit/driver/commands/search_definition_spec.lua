local CommandKind = require('dwarfspec.protocol.enums.command_kinds')
local Harness = dofile('tests/unit/driver/command/engine_harness.lua')
local SearchDefinition = require(
    'dwarfspec.driver.commands.search_definition')
local TestRunner = dofile(
    'tests/unit/driver/commands/definition_test_support.lua')

---@class dwarfspec.tests.SearchDefinitionDependencies
local Dependencies = {}

---Creates isolated search-definition dependencies.
---@param result? any
---@return table
function Dependencies.new(result)
    local mount = {interaction_target={assert_current=function() end}}
    local mount_context = {
        is_subject=function(_, value) return value == 'subject' end,
        require_current=function() return mount end,
        resolve_subject=function(_, subject) return subject end,
    }
    return {mount_context=mount_context,
        normalize_query=function(value) return value end,
        normalize_rectangle=function(value) return value end,
        search=function() return result end}
end

describe('verified search command definition', function()
    it('owns registration and public query binding', function()
        local runner, ds = TestRunner.new(), {}
        SearchDefinition.bind(ds, runner, Dependencies.new())
        local options = {timeout_ms=10}
        assert.equals('search', ds.search('text', 'subject', options))
        assert.same({'search'}, runner:names())
        local invocation = runner:invocations()[1]
        assert.equals('text', invocation.arguments.query)
        assert.is_true(invocation.arguments.search_area_is_subject)
        assert.equals(options, invocation.options)
        assert.equals(CommandKind.QUERY,
            runner:definition('search').kind)
    end)

    it('distinguishes a successful nil observation from pending', function()
        local harness = Harness.new()
        local definition = SearchDefinition.new(Dependencies.new()):definition()
        harness:register(TestRunner.fixture(definition))
        assert.is_nil(harness:invoke('search', {}))
    end)

    it('projects a plain observation into caller verification', function()
        local harness = Harness.new()
        local rectangle = {x1=1, y1=2, x2=3, y2=4}
        local definition = SearchDefinition.new(
            Dependencies.new(rectangle)):definition()
        harness:register(TestRunner.fixture(definition))
        assert.same(rectangle, harness:invoke('search', {}, {
            verify=function(observation)
                return observation.public_result.x1 == 1 and
                    observation.public_result.y2 == 4
            end}))
    end)
end)
