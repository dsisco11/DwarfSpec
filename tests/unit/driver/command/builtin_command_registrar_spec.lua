local Registrar = require(
    'dwarfspec.driver.command.builtin_command_registrar')
local Definition = require('dwarfspec.driver.command.definition')
local CommandKind = require('dwarfspec.protocol.enums.command_kinds')
local IntrinsicKind = require(
    'dwarfspec.protocol.enums.intrinsic_verification_kinds')
local Outcomes = require('dwarfspec.driver.command.outcomes')
local RetryPolicy = require(
    'dwarfspec.protocol.enums.execution_retry_policies')

---@class dwarfspec.tests.BuiltinOwner
local Owner = {}
Owner.__index = Owner

---Creates one test command owner.
---@param name string
---@param binding? table
---@return dwarfspec.tests.BuiltinOwner
function Owner.new(name, binding)
    return setmetatable({_name=name, _binding=binding}, Owner)
end

---Returns the test command definition.
---@return table
function Owner:definition()
    if self._name == 'invalid-definition' then return {name=self._name} end
    return Definition.validate({name=self._name, kind=CommandKind.QUERY,
        normalize=function(arguments) return arguments end,
        preflight=function() return Outcomes.ready(true) end,
        execute=function(_, request) return Outcomes.ready(request.value) end,
        execution_retry_policy=RetryPolicy.ONCE,
        intrinsic_verification=IntrinsicKind.PRIMARY_OBSERVATION})
end

---Returns the optional test binding declaration.
---@return table|nil
function Owner:binding()
    return self._binding
end

---Adapts test invocation arguments.
---@param value any
---@param options? table
---@return table, table|nil
function Owner:arguments(value, options)
    return {value=value}, options
end

describe('built-in command registrar', function()
    local function fixture(ds, subject)
        local registrations, invocations = {}, {}
        local runner = {
            registerBuiltin=function(_, definition)
                registrations[#registrations + 1] = definition.name
                return definition
            end,
            invoke=function(_, name, request, options)
                invocations[#invocations + 1] = {name=name,
                    request=request, options=options}
                return 'result', nil, false
            end,
        }
        return Registrar.new({runner=runner, ds=ds or {},
            subject=subject or {}}), registrations, invocations, runner
    end

    it('registers in order and preserves arguments and return values', function()
        local ds = {}
        local registrar, registrations, invocations = fixture(ds)
        local accepted = registrar:register_all({Owner.new('first'),
            Owner.new('second')})
        assert.same({'first', 'second'}, registrations)
        assert.equals('first', accepted[1].name)
        local first, second, third = ds.second('value', {timeout_ms=9})
        assert.equals('result', first)
        assert.is_nil(second)
        assert.is_false(third)
        assert.same({name='second', request={value='value'},
            options={timeout_ms=9}}, invocations[1])
    end)

    it('uses the exact injected runner for every public closure', function()
        local ds = {}
        local registrar, _, _, runner = fixture(ds)
        registrar:register(Owner.new('query'))
        runner.invoke = function(self, name)
            assert.equals(runner, self)
            assert.equals('query', name)
            return 42
        end
        assert.equals(42, ds.query())
    end)

    it('installs qualified commands only on the explicit subject surface',
            function()
        local ds, subject = {}, {}
        local registrar = fixture(ds, subject)
        registrar:register(Owner.new('subject.raw',
            {surface='subject', name='raw'}))
        assert.is_nil(ds.raw)
        assert.equals('result', subject.raw('subject'))
    end)

    it('rejects duplicates, mismatches, and namespace replacement', function()
        local registrar = fixture({occupied=function() end})
        assert.has_error(function()
            registrar:register(Owner.new('occupied'))
        end, 'built-in command cannot replace ds.occupied')
        registrar = fixture({})
        registrar:register(Owner.new('same'))
        assert.has_error(function()
            registrar:register(Owner.new('same'))
        end, 'duplicate built-in command definition "same"')
        registrar = fixture({})
        assert.has_error(function()
            registrar:register(Owner.new('subject.raw',
                {surface='subject', name='wrong'}))
        end, 'subject command binding must match its qualified definition')
    end)

    it('rejects invalid owner contracts and unordered collections', function()
        local registrar = fixture({})
        assert.has_error(function() registrar:register({}) end,
            'built-in command owner must be a class-like table')
        local invalid = setmetatable({}, {__index={
            definition=function() return {name='invalid'} end,
        }})
        assert.has_error(function() registrar:register(invalid) end,
            'built-in command owner requires arguments(...)')
        assert.has_error(function()
            registrar:register_all({Owner.new('valid'), extra=true})
        end, 'built-in commands must be an ordered array')
        local accepted, failure = pcall(registrar.register, registrar,
            Owner.new('invalid-definition'))
        assert.is_false(accepted)
        assert.matches('must return a validated immutable definition',
            failure, 1, true)
    end)
end)
