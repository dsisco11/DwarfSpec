-- Canonical registration and public binding for verified built-in commands.

local Definition = require('dwarfspec.driver.command.definition')

---@class dwarfspec.BuiltinCommandRegistrar
---@field private _runner dwarfspec.CommandRunner
---@field private _surfaces table<string, table>
---@field private _definitions table<string, true>
---@field private _bindings table<string, table<string, true>>
local BuiltinCommandRegistrar = {}
BuiltinCommandRegistrar.__index = BuiltinCommandRegistrar

---Creates a registrar for one runner and its explicit public surfaces.
---@param options table
---@return dwarfspec.BuiltinCommandRegistrar
function BuiltinCommandRegistrar.new(options)
    assert(type(options) == 'table',
        'built-in command registrar options are required')
    assert(type(options.runner) == 'table' and
            type(options.runner.registerBuiltin) == 'function' and
            type(options.runner.invoke) == 'function',
        'built-in command registrar requires the verified command runner')
    assert(type(options.ds) == 'table',
        'built-in command registrar requires the ds surface')
    assert(options.subject == nil or type(options.subject) == 'table',
        'built-in command registrar subject surface must be a table')
    return setmetatable({
        _runner=options.runner,
        _surfaces={ds=options.ds, subject=options.subject or {}},
        _definitions={},
        _bindings={ds={}, subject={}},
    }, BuiltinCommandRegistrar)
end

---Returns and validates one command owner's public binding declaration.
---@param owner table
---@param definition table
---@return string, string
function BuiltinCommandRegistrar:_binding(owner, definition)
    local surface, public_name = 'ds', definition.name
    if type(owner.binding) == 'function' then
        local binding = owner:binding()
        if binding ~= nil then
            assert(type(binding) == 'table',
                'built-in command binding must be a table')
            surface = binding.surface
            public_name = binding.name
        end
    end
    assert(surface == 'ds' or surface == 'subject',
        'built-in command binding has an unsupported surface')
    assert(type(public_name) == 'string' and public_name ~= '',
        'built-in command binding name must be a nonempty string')
    if surface == 'ds' then
        assert(public_name == definition.name,
            'ds command binding name must match its definition')
        assert(not definition.name:find('.', 1, true),
            'qualified command definitions require an explicit surface')
    else
        assert(definition.name == 'subject.' .. public_name,
            'subject command binding must match its qualified definition')
    end
    return surface, public_name
end

---Registers one owner and installs its exact runner-backed public closure.
---@param owner table
---@return dwarfspec.CommandDefinition
function BuiltinCommandRegistrar:register(owner)
    assert(type(owner) == 'table' and getmetatable(owner) ~= nil,
        'built-in command owner must be a class-like table')
    assert(type(owner.definition) == 'function',
        'built-in command owner requires definition()')
    assert(type(owner.arguments) == 'function',
        'built-in command owner requires arguments(...)')
    local definition = owner:definition()
    assert(Definition.is_validated(definition),
        'built-in command owner must return a validated immutable definition')
    assert(not self._definitions[definition.name],
        ('duplicate built-in command definition %q'):format(definition.name))
    local surface_name, public_name = self:_binding(owner, definition)
    local surface = self._surfaces[surface_name]
    assert(not self._bindings[surface_name][public_name],
        ('duplicate %s command binding %q'):format(
            surface_name, public_name))
    assert(surface[public_name] == nil,
        ('built-in command cannot replace %s.%s'):format(
            surface_name, public_name))
    local accepted = self._runner:registerBuiltin(definition)
    assert(accepted.name == definition.name,
        'registered built-in definition name changed')
    local runner = self._runner
    surface[public_name] = function(...)
        local request, command_options = owner:arguments(...)
        assert(type(request) == 'table',
            'built-in command arguments must return a request table')
        return runner:invoke(accepted.name, request, command_options)
    end
    self._definitions[accepted.name] = true
    self._bindings[surface_name][public_name] = true
    return accepted
end

---Registers an explicit ordered array of built-in command owners.
---@param owners table[]
---@return dwarfspec.CommandDefinition[]
function BuiltinCommandRegistrar:register_all(owners)
    assert(type(owners) == 'table',
        'built-in command registration requires an ordered array')
    local accepted = {}
    local count = 0
    for index, owner in ipairs(owners) do
        count = count + 1
        accepted[index] = self:register(owner)
    end
    for key in pairs(owners) do
        assert(type(key) == 'number' and key >= 1 and key <= count and
                key % 1 == 0,
            'built-in commands must be an ordered array')
    end
    return accepted
end

---Returns the explicit subject-method surface after registration.
---@return table<string, function>
function BuiltinCommandRegistrar:subject_surface()
    return self._surfaces.subject
end

return BuiltinCommandRegistrar
