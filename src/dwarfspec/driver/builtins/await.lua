-- Verified await command owner.

local CommandKind = require('dwarfspec.protocol.enums.command_kinds')
local OpaqueTokens = require('dwarfspec.driver.command.opaque_tokens')
local ReadOnlyDefinition = require(
    'dwarfspec.driver.command.read_only_definition')
local WaitSupport = require('dwarfspec.driver.builtins.wait_support')

---@class dwarfspec.AwaitCommand
local Await = {}
Await.__index = Await

---Creates the await command owner.
---@param runtime dwarfspec.WaitRuntime
---@return dwarfspec.AwaitCommand
function Await.new(runtime)
    return setmetatable({_runtime=assert(runtime),
        _support=WaitSupport.new(), _opaque=OpaqueTokens.new()}, Await)
end

---Creates the await definition.
---@return dwarfspec.CommandDefinition
function Await:definition()
    return ReadOnlyDefinition.new({name='await', kind=CommandKind.ASSERTION,
        normalize=function(arguments)
            assert(type(arguments.description) == 'string' and
                    arguments.description ~= '',
                'wait description must be a nonempty string')
            assert(type(arguments.query) == 'function',
                'wait query must be a function')
            return {description=arguments.description,
                query_token=self._opaque:retain(arguments.query),
                options=self._support:options(arguments.options, true, false)}
        end,
        observe=function(context, request)
            return self._support:observe(function()
                return self._runtime:wait_until(request.description,
                    self._opaque:resolve(request.query_token), request.options,
                    context:remaining_ms())
            end)
        end}):definition()
end

---Adapts the public await signature for the runner.
---@param description string
---@param query function
---@param options? table
---@param command_options? table
---@return table, table|nil
function Await:arguments(description, query, options, command_options)
    return {description=description, query=query, options=options},
        self._support:command_options(options, command_options)
end

return Await
