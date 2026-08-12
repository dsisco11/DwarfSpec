-- Verified definitions for public wait assertions.

local CommandKind = require('dwarfspec.protocol.enums.command_kinds')
local ReadOnlyDefinition = require(
    'dwarfspec.driver.command.read_only_definition')
local OpaqueTokens = require('dwarfspec.driver.command.opaque_tokens')
local Outcomes = require('dwarfspec.driver.command.outcomes')

---@class dwarfspec.WaitCommandDefinitions
---@field private _operations table<string, function>
local WaitDefinitions = {}
WaitDefinitions.__index = WaitDefinitions

---Creates the wait-definition owner.
---@param operations table<string, function>
---@return dwarfspec.WaitCommandDefinitions
function WaitDefinitions.new(operations)
    assert(type(operations) == 'table',
        'wait definitions require scheduling operations')
    for _, name in ipairs({'wait_frames', 'wait_ticks', 'wait_event',
            'wait_until'}) do
        assert(type(operations[name]) == 'function',
            'wait definitions require ' .. name)
    end
    return setmetatable({_opaque=OpaqueTokens.new(),
        _operations=operations}, WaitDefinitions)
end

---Validates and returns one legacy timeout option.
---@param options table|nil
---@return number|boolean|nil
function WaitDefinitions:_legacy_timeout(options)
    local value = options and options.timeout_ms
    assert(value == nil or value == false or
            type(value) == 'number' and value >= 1 and value < math.huge and
            value % 1 == 0,
        'wait timeout must be false or a positive finite integer')
    return value
end

---Copies and validates legacy wait options without owning a deadline.
---@param options any
---@param allow_frame_budget boolean
---@return table
function WaitDefinitions:_options(options, allow_frame_budget)
    assert(options == nil or type(options) == 'table',
        'wait options must be a table')
    self:_legacy_timeout(options)
    local copy = {}
    for name, value in pairs(options or {}) do
        assert(name == 'description' or
                allow_frame_budget and name == 'frame_budget' or
                name == 'timeout_ms',
            'unsupported wait option: ' .. tostring(name))
        if name ~= 'timeout_ms' then copy[name] = value end
    end
    assert(copy.description == nil or
            type(copy.description) == 'string' and copy.description ~= '',
        'wait description must be a nonempty string')
    assert(copy.frame_budget == nil or
            type(copy.frame_budget) == 'number' and
            copy.frame_budget >= 1 and copy.frame_budget % 1 == 0,
        'frame budget must be a positive integer')
    return copy
end

---Validates a positive progress count.
---@param count any
---@param label string
---@return integer
function WaitDefinitions:_count(count, label)
    assert(type(count) == 'number' and count >= 1 and count % 1 == 0,
        label .. ' count must be a positive integer')
    return count
end

---Applies the legacy positive timeout when trailing options omit one.
---@param options table|nil
---@param command_options table|nil
---@return table|nil
function WaitDefinitions:_command_options(options, command_options)
    self:_legacy_timeout(options)
    if options == nil or type(options.timeout_ms) ~= 'number' or
            command_options ~= nil and command_options.timeout_ms ~= nil then
        return command_options
    end
    local copy = {}
    for name, value in pairs(command_options or {}) do copy[name] = value end
    copy.timeout_ms = options.timeout_ms
    return copy
end

---Normalizes one real wait operation result into a gate observation.
---@param operation function
---@return table
function WaitDefinitions:_observe(operation)
    local result = operation()
    if Outcomes.is_gate(result) then
        return Outcomes.validate_gate(result)
    end
    return Outcomes.ready(result,
        {completed=true})
end

---Creates all wait assertion definitions.
---@return table[]
function WaitDefinitions:definitions()
    local definitions = {}
    definitions[#definitions + 1] = ReadOnlyDefinition.new({
        name='wait_frames', kind=CommandKind.ASSERTION,
        normalize=function(arguments)
            return {count=self:_count(arguments.count, 'frame'),
                options=self:_options(arguments.options, false)}
        end,
        observe=function(context, request)
            return self:_observe(function()
                return self._operations.wait_frames(request.count,
                    request.options, context:remaining_ms())
            end)
        end}):definition()
    definitions[#definitions + 1] = ReadOnlyDefinition.new({
        name='wait_ticks', kind=CommandKind.ASSERTION,
        normalize=function(arguments)
            return {count=self:_count(arguments.count, 'simulation tick'),
                options=self:_options(arguments.options, false)}
        end,
        observe=function(context, request)
            return self:_observe(function()
                return self._operations.wait_ticks(request.count,
                    request.options, context:remaining_ms())
            end)
        end}):definition()
    definitions[#definitions + 1] = ReadOnlyDefinition.new({
        name='await', kind=CommandKind.ASSERTION,
        normalize=function(arguments)
            assert(type(arguments.description) == 'string' and
                    arguments.description ~= '',
                'wait description must be a nonempty string')
            assert(type(arguments.query) == 'function',
                'wait query must be a function')
            return {description=arguments.description,
                query_token=self._opaque:retain(arguments.query),
                options=self:_options(arguments.options, true)}
        end,
        observe=function(context, request)
            return self:_observe(function()
                return self._operations.wait_until(request.description,
                    self._opaque:resolve(request.query_token), request.options,
                    context:remaining_ms())
            end)
        end}):definition()
    definitions[#definitions + 1] = ReadOnlyDefinition.new({
        name='awaitEvent', kind=CommandKind.ASSERTION,
        normalize=function(arguments)
            assert(arguments.event ~= nil, 'awaitEvent requires an event')
            assert(arguments.options == nil or
                    type(arguments.options) == 'table',
                'awaitEvent options must be a table')
            self:_legacy_timeout(arguments.options)
            local options = {}
            for name, value in pairs(arguments.options or {}) do
                assert(name == 'trigger' or name == 'description' or
                        name == 'timeout_ms',
                    'awaitEvent options contain unsupported field: ' ..
                        tostring(name))
                if name == 'trigger' then
                    assert(type(value) == 'function',
                        'awaitEvent trigger must be a function')
                    options.trigger_token = self._opaque:retain(value)
                elseif name ~= 'timeout_ms' then
                    options[name] = value
                end
            end
            return {event=arguments.event, options=options}
        end,
        observe=function(context, request)
            return self:_observe(function()
                local options = {}
                for name, value in pairs(request.options) do
                    if name ~= 'trigger_token' then options[name] = value end
                end
                if request.options.trigger_token then
                    options.trigger = self._opaque:resolve(
                        request.options.trigger_token)
                end
                return self._operations.wait_event(request.event, options,
                    context:remaining_ms())
            end)
        end}):definition()
    return definitions
end

---Registers and binds all public wait assertions.
---@param ds table
---@param command_runner dwarfspec.CommandRunner
---@param operations table<string, function>
function WaitDefinitions.bind(ds, command_runner, operations)
    local owner = WaitDefinitions.new(operations)
    for _, definition in ipairs(owner:definitions()) do
        command_runner:registerBuiltin(definition)
    end

    ---Waits for an exact number of rendered frames.
    ---@param count integer
    ---@param options? table
    ---@param command_options? table
    ---@return integer
    function ds.wait_frames(count, options, command_options)
        return command_runner:invoke('wait_frames',
            {count=count, options=options},
            owner:_command_options(options, command_options))
    end

    ---Waits for an exact number of simulation ticks.
    ---@param count integer
    ---@param options? table
    ---@param command_options? table
    ---@return integer
    function ds.wait_ticks(count, options, command_options)
        return command_runner:invoke('wait_ticks',
            {count=count, options=options},
            owner:_command_options(options, command_options))
    end

    ---Polls a read-only predicate until it succeeds.
    ---@param description string
    ---@param query function
    ---@param options? table
    ---@param command_options? table
    ---@return any
    function ds.await(description, query, options, command_options)
        return command_runner:invoke('await', {description=description,
            query=query, options=options},
            owner:_command_options(options, command_options))
    end

    ---Waits for one exact native event occurrence.
    ---@param event any
    ---@param options? table
    ---@param command_options? table
    ---@return table
    function ds.awaitEvent(event, options, command_options)
        return command_runner:invoke('awaitEvent',
            {event=event, options=options},
            owner:_command_options(options, command_options))
    end
end

return WaitDefinitions
