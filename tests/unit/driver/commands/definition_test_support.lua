local Registry = require('dwarfspec.driver.command.registry')

---@class dwarfspec.tests.CommandDefinitionRunner
---@field private _registry dwarfspec.CommandRegistry
---@field private _invocations table[]
local TestRunner = {}
TestRunner.__index = TestRunner

---Creates a generic registration and invocation recorder.
---@return dwarfspec.tests.CommandDefinitionRunner
function TestRunner.new()
    return setmetatable({_registry=Registry.new(), _invocations={}}, TestRunner)
end

---Registers one definition through the production validator.
---@param definition table
---@return table
function TestRunner:registerBuiltin(definition)
    return self._registry:register_builtin(definition)
end

---Records one public binding invocation.
---@param name string
---@param arguments table
---@param options? table
---@return string
function TestRunner:invoke(name, arguments, options)
    self._invocations[#self._invocations + 1] = {name=name,
        arguments=arguments, options=options}
    return name
end

---Returns registered command names in lexical order.
---@return string[]
function TestRunner:names()
    return self._registry:names()
end

---Returns one registered validated definition.
---@param name string
---@return table
function TestRunner:definition(name)
    return assert(self._registry:get(name))
end

---Returns recorded public invocations.
---@return table[]
function TestRunner:invocations()
    return self._invocations
end

---Builds the generic engine qualification declaration.
---@param definition table
---@return table
function TestRunner.fixture(definition)
    return {definition=definition, gate='ready', execution='completed',
        intrinsic=definition.intrinsic_verification, timeout='finite',
        retry_safety=definition.execution_retry_policy,
        cleanup=definition.cleanup and 'declared' or 'none',
        expected_observations={'terminal completion'}}
end

return TestRunner
