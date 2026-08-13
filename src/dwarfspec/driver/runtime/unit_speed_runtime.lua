-- Cohesive recurring unit-speed ownership capability.

---@class dwarfspec.UnitSpeedRuntime
---@field private _controller_provider function
local UnitSpeedRuntime = {}
UnitSpeedRuntime.__index = UnitSpeedRuntime

---Creates the unit-speed capability.
---@param controller table|function
---@return dwarfspec.UnitSpeedRuntime
function UnitSpeedRuntime.new(controller)
    assert(type(controller) == 'table' or type(controller) == 'function',
        'unit-speed runtime requires a controller')
    local provider = type(controller) == 'function' and controller or
        function() return controller end
    if type(controller) == 'table' then
        for _, name in ipairs({'prepare', 'activate_prepared', 'state',
                'restore'}) do
            assert(type(controller[name]) == 'function',
                'unit-speed runtime requires controller ' .. name)
        end
    end
    return setmetatable({_controller_provider=provider}, UnitSpeedRuntime)
end

---Returns the current run-owned controller.
---@return table
function UnitSpeedRuntime:_controller()
    local controller = self._controller_provider()
    assert(type(controller) == 'table',
        'unit-speed controller provider returned an invalid controller')
    return controller
end

---Preflights and snapshots the requested target/configuration set.
---@param options table
---@return table
function UnitSpeedRuntime:prepare(options)
    return self:_controller():prepare(options)
end

---Activates one preflighted immutable-shaped snapshot.
---@param configuration table
function UnitSpeedRuntime:activate(configuration)
    return self:_controller():activate_prepared(configuration)
end

---Returns authoritative recurring-operation ownership.
---@return table
function UnitSpeedRuntime:state()
    return self:_controller():state()
end

---Stops recurring work and restores derived position ownership.
function UnitSpeedRuntime:restore()
    return self:_controller():restore()
end

return UnitSpeedRuntime
