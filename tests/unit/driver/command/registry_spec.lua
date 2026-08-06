-- Deterministic merge and diagnostics contracts for command registration.

local CommandKind = require('dwarfspec.protocol.enums.command_kinds')
local Outcomes = require('dwarfspec.driver.command.outcomes')
local Registry = require('dwarfspec.driver.command.registry')

---Creates one structurally valid read-only definition.
---@param name string
---@return table
local function definition(name)
    return {
        name=name, kind=CommandKind.QUERY,
        normalize=function(arguments) return arguments end,
        preflight=function() return Outcomes.ready() end,
        execute=function() return Outcomes.ready() end,
        execution_retry_policy='once',
        intrinsic_verification='primary_observation',
    }
end

---Asserts that a callback fails with all diagnostic fragments.
---@param callback fun()
---@param fragments string[]
local function assert_error(callback, fragments)
    local succeeded, message = pcall(callback)
    assert.is_false(succeeded)
    for _, fragment in ipairs(fragments) do
        assert.is_truthy(tostring(message):find(fragment, 1, true))
    end
end

describe('command registry', function()
    it('merges built-ins and projects into deterministic lexical lookup',
            function()
        local registry = Registry.new()
        registry:merge({definition('zeta'), definition('alpha')}, {
            {definition=definition('project_b'), source_path='b.lua'},
            {definition=definition('project_a'), source_path='a.lua'},
        })
        assert.same({'alpha', 'project_a', 'project_b', 'zeta'},
            registry:names())
        assert.equals('project_a', registry:get('project_a').name)
    end)

    it('rejects duplicates and replacement of reserved built-ins', function()
        local registry = Registry.new({reserved_names={'reserved'}})
        registry:register_builtin(definition('built_in'))
        assert_error(function()
            registry:register_builtin(definition('built_in'))
        end, {'duplicate', 'built_in'})
        assert_error(function()
            registry:register_project(definition('built_in'), 'commands/x.lua')
        end, {'commands/x.lua', 'built_in', 'reserved'})
        assert_error(function()
            registry:register_project(definition('reserved'), 'commands/y.lua')
        end, {'commands/y.lua', 'reserved'})
    end)

    it('preserves project source and command name for invalid definitions',
            function()
        local registry = Registry.new()
        local invalid = definition('broken')
        invalid.preflight = nil
        assert_error(function()
            registry:register_project(invalid, 'project/commands/broken.lua')
        end, {'project/commands/broken.lua', 'broken', 'preflight'})
    end)

    it('retains immutable snapshots after registration', function()
        local registry = Registry.new()
        local source = definition('stable')
        local accepted = registry:register_builtin(source)
        source.name = 'changed'
        assert.equals('stable', registry:get('stable').name)
        assert.equals(accepted, registry:get('stable'))
        assert.has_error(function() accepted.name = 'changed' end)
    end)
end)
