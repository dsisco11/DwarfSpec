-- Immutable enum values for structured automation event identifiers.

---@class DwarfSpecEventType
---@field id string Stable serialized event identifier.
---@field name string Stable symbolic enum member name.

---@class DwarfSpecEventTypeEnum
---@field RUN_QUEUED DwarfSpecEventType
---@field RUN_ACTIVATED DwarfSpecEventType
---@field RUN_CANCELLED DwarfSpecEventType
---@field RUN_STARTED DwarfSpecEventType
---@field REPEAT_STARTED DwarfSpecEventType
---@field REPEAT_FINISHED DwarfSpecEventType
---@field TEST_STARTED DwarfSpecEventType
---@field TEST_FINISHED DwarfSpecEventType
---@field PROBLEM_RECORDED DwarfSpecEventType
---@field COMMAND_STARTED DwarfSpecEventType
---@field COMMAND_FINISHED DwarfSpecEventType
---@field DIAGNOSTIC_RECORDED DwarfSpecEventType
---@field CLEANUP_STARTED DwarfSpecEventType
---@field CLEANUP_FAILED DwarfSpecEventType
---@field CLEANUP_FINISHED DwarfSpecEventType
---@field RUN_ABORTED DwarfSpecEventType
---@field RUN_FINISHED DwarfSpecEventType
---@field SCHEDULER_BLOCKED DwarfSpecEventType
---@field is fun(value: any): boolean
---@field id fun(value: DwarfSpecEventType): string
---@field name fun(value: DwarfSpecEventType): string
---@field from_id fun(id: string): DwarfSpecEventType|nil
---@field values fun(): DwarfSpecEventType[]

local DEFINITIONS = {
    RUN_QUEUED='run.queued',
    RUN_ACTIVATED='run.activated',
    RUN_CANCELLED='run.cancelled',
    RUN_STARTED='run.started',
    REPEAT_STARTED='repeat.started',
    REPEAT_FINISHED='repeat.finished',
    TEST_STARTED='test.started',
    TEST_FINISHED='test.finished',
    PROBLEM_RECORDED='problem.recorded',
    COMMAND_STARTED='command.started',
    COMMAND_FINISHED='command.finished',
    DIAGNOSTIC_RECORDED='diagnostic.recorded',
    CLEANUP_STARTED='cleanup.started',
    CLEANUP_FAILED='cleanup.failed',
    CLEANUP_FINISHED='cleanup.finished',
    RUN_ABORTED='run.aborted',
    RUN_FINISHED='run.finished',
    SCHEDULER_BLOCKED='scheduler.blocked',
}

local constants = {}
local ids = {}
local names = {}
local values = {}

---Rejects mutation of an immutable event-type value or enum.
---@param target table
---@param key any
local function reject_mutation(target, key)
    error('DwarfSpec EventType is immutable: ' .. tostring(key), 2)
end

---Returns one immutable event-type value property.
---@param value DwarfSpecEventType
---@param key any
---@return string|nil
local function value_index(value, key)
    if key == 'id' then return ids[value] end
    if key == 'name' then return names[value] end
    return nil
end

---Returns one event-type value's wire identifier.
---@param value DwarfSpecEventType
---@return string
local function value_tostring(value)
    return ids[value]
end

local VALUE_METATABLE = {
    __index=value_index,
    __metatable='DwarfSpec EventType value',
    __newindex=reject_mutation,
    __tostring=value_tostring,
}

for name, id in pairs(DEFINITIONS) do
    local value = setmetatable({}, VALUE_METATABLE)
    constants[name] = value
    ids[value] = id
    names[value] = name
    values[#values + 1] = value
end

---Orders event-type values by wire identifier.
---@param left DwarfSpecEventType
---@param right DwarfSpecEventType
---@return boolean
local function id_before(left, right)
    return ids[left] < ids[right]
end

table.sort(values, id_before)

local by_id = {}
for value, id in pairs(ids) do by_id[id] = value end

local methods = {}

---Returns whether a value is a DwarfSpec event-type enum member.
---@param value any
---@return boolean
function methods.is(value)
    return ids[value] ~= nil
end

---Returns the wire identifier for one event-type enum member.
---@param value DwarfSpecEventType
---@return string
function methods.id(value)
    local id = ids[value]
    assert(id ~= nil, 'value must be a DwarfSpec EventType')
    return id
end

---Returns the symbolic name for one event-type enum member.
---@param value DwarfSpecEventType
---@return string
function methods.name(value)
    local name = names[value]
    assert(name ~= nil, 'value must be a DwarfSpec EventType')
    return name
end

---Returns the enum member represented by a wire identifier.
---@param id string
---@return DwarfSpecEventType|nil
function methods.from_id(id)
    return by_id[id]
end

---Returns all event-type members ordered by wire identifier.
---@return DwarfSpecEventType[]
function methods.values()
    local result = {}
    for index, value in ipairs(values) do result[index] = value end
    return result
end

---Returns immutable enum members and helper methods by name.
---@param target table
---@param key any
---@return any
local function enum_index(target, key)
    return constants[key] or methods[key]
end

---Iterates the immutable symbolic event-type members.
---@return function, table, nil
local function enum_pairs()
    return next, constants, nil
end

---@type DwarfSpecEventTypeEnum
local EventType = setmetatable({}, {
    __index=enum_index,
    __metatable='DwarfSpec EventType enum',
    __newindex=reject_mutation,
    __pairs=enum_pairs,
})

return EventType
