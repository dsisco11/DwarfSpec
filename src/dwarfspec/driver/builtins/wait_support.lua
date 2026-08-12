-- Shared validation and observation mechanics for wait command owners.

local Outcomes = require('dwarfspec.driver.command.outcomes')

---@class dwarfspec.WaitCommandSupport
local WaitSupport = {}
WaitSupport.__index = WaitSupport

---Creates stateless wait-command support.
---@return dwarfspec.WaitCommandSupport
function WaitSupport.new()
    return setmetatable({}, WaitSupport)
end

---Validates and returns a legacy timeout option.
---@param options? table
---@return number|boolean|nil
function WaitSupport:legacy_timeout(options)
    local value = options and options.timeout_ms
    assert(value == nil or value == false or
            type(value) == 'number' and value >= 1 and value < math.huge and
            value % 1 == 0,
        'wait timeout must be false or a positive finite integer')
    return value
end

---Copies validated wait options without owning a deadline.
---@param options any
---@param allow_frame_budget boolean
---@param allow_trigger boolean
---@return table
function WaitSupport:options(options, allow_frame_budget, allow_trigger)
    assert(options == nil or type(options) == 'table',
        'wait options must be a table')
    self:legacy_timeout(options)
    local copy = {}
    for name, value in pairs(options or {}) do
        assert(name == 'description' or
                allow_frame_budget and name == 'frame_budget' or
                allow_trigger and name == 'trigger' or
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
    assert(copy.trigger == nil or type(copy.trigger) == 'function',
        'awaitEvent trigger must be a function')
    return copy
end

---Validates one positive wait count.
---@param count any
---@param label string
---@return integer
function WaitSupport:count(count, label)
    assert(type(count) == 'number' and count >= 1 and count % 1 == 0,
        label .. ' count must be a positive integer')
    return count
end

---Selects trailing command options after validating the legacy timeout.
---@param options? table
---@param command_options? table
---@return table|nil
function WaitSupport:command_options(options, command_options)
    self:legacy_timeout(options)
    if options == nil or type(options.timeout_ms) ~= 'number' or
            command_options ~= nil and command_options.timeout_ms ~= nil then
        return command_options
    end
    local copy = {}
    for name, value in pairs(command_options or {}) do copy[name] = value end
    copy.timeout_ms = options.timeout_ms
    return copy
end

---Normalizes a runtime wait result into a runner gate.
---@param operation function
---@return table
function WaitSupport:observe(operation)
    local result = operation()
    if Outcomes.is_gate(result) then return Outcomes.validate_gate(result) end
    return Outcomes.ready(result, {completed=true})
end

return WaitSupport
