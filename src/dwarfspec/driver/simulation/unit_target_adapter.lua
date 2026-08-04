-- Native unit targeting for run-owned simulation commands.

local M = {}

local diagnostic_id_limit = 16

---Requires one callable dependency.
---@param dependencies table
---@param name string
---@return function
local function require_function(dependencies, name)
    local value = dependencies and dependencies[name]
    assert(type(value) == 'function',
        'unit target adapter requires dependency: ' .. name)
    return value
end

---Formats a bounded list of unit IDs for one validation diagnostic.
---@param label string
---@param ids integer[]
---@return string
local function format_ids(label, ids)
    local displayed = {}
    local count = math.min(#ids, diagnostic_id_limit)
    for index = 1, count do displayed[index] = tostring(ids[index]) end
    local suffix = ''
    if #ids > count then
        suffix = (' (+%d more)'):format(#ids - count)
    end
    return label .. ': ' .. table.concat(displayed, ', ') .. suffix
end

---Creates an adapter that owns native target discovery and re-resolution.
---@param dependencies table
---@return table
function M.new(dependencies)
    assert(type(dependencies) == 'table',
        'unit target adapter requires dependencies')
    local is_world_loaded = require_function(dependencies, 'is_world_loaded')
    local is_map_loaded = require_function(dependencies, 'is_map_loaded')
    local is_fortress_mode = require_function(dependencies, 'is_fortress_mode')
    local enumerate_units = require_function(dependencies, 'enumerate_units')
    local resolve_unit = require_function(dependencies, 'resolve_unit')
    local is_active = require_function(dependencies, 'is_active')
    local is_alive = require_function(dependencies, 'is_alive')
    local is_citizen = require_function(dependencies, 'is_citizen')
    local is_resident = require_function(dependencies, 'is_resident')
    local adapter = {}

    ---Returns whether the loaded game state supports unit-speed work.
    ---@return boolean
    function adapter:is_ready()
        return is_world_loaded() and is_map_loaded() and is_fortress_mode()
    end

    ---Fails unless a loaded fortress map supports target activation.
    function adapter:assert_ready()
        assert(is_world_loaded(),
            'DwarfSpec setUnitSpeed requires a loaded world')
        assert(is_map_loaded(),
            'DwarfSpec setUnitSpeed requires a loaded map')
        assert(is_fortress_mode(),
            'DwarfSpec setUnitSpeed requires a loaded fortress site')
    end

    ---Returns whether one resolved unit belongs to the accepted population.
    ---@param unit any
    ---@return boolean
    function adapter:is_eligible(unit)
        return unit ~= nil and is_active(unit) and is_alive(unit) and
            (is_citizen(unit, false) or is_resident(unit, false))
    end

    ---Captures eligible default targets once in deterministic ID order.
    ---@return integer[]
    function adapter:capture_default_ids()
        local ids = {}
        for _, unit in ipairs(enumerate_units()) do
            if self:is_eligible(unit) then ids[#ids + 1] = unit.id end
        end
        table.sort(ids)
        return ids
    end

    ---Validates explicit IDs and reports all resolution failures together.
    ---@param requested_ids integer[]
    ---@return integer[]
    function adapter:capture_explicit_ids(requested_ids)
        local ids = {}
        local invalid = {}
        local ineligible = {}
        for index, id in ipairs(requested_ids) do
            local unit = resolve_unit(id)
            if unit == nil then
                invalid[#invalid + 1] = id
            elseif not self:is_eligible(unit) then
                ineligible[#ineligible + 1] = id
            else
                ids[index] = id
            end
        end
        if #invalid > 0 or #ineligible > 0 then
            local details = {}
            if #invalid > 0 then
                details[#details + 1] = format_ids('invalid unit ids', invalid)
            end
            if #ineligible > 0 then
                details[#details + 1] =
                    format_ids('ineligible unit ids', ineligible)
            end
            error(table.concat(details, '; '), 2)
        end
        return ids
    end

    ---Visits captured targets that still resolve and remain eligible.
    ---@param ids integer[]
    ---@param callback fun(unit:any, id:integer)
    ---@return boolean
    function adapter:for_each_available(ids, callback)
        assert(type(callback) == 'function',
            'unit target callback must be a function')
        if not self:is_ready() then return false end
        for _, id in ipairs(ids) do
            local unit = resolve_unit(id)
            if self:is_eligible(unit) then callback(unit, id) end
        end
        return true
    end

    return adapter
end

return M
