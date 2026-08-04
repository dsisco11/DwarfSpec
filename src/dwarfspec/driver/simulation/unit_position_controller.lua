-- Run-owned coordinate rollback shared by explicit placement and job travel.

local M = {}

---Returns whether a value is an integer.
---@param value any
---@return boolean
local function is_integer(value)
    return type(value) == 'number' and value == value and
        value ~= math.huge and value ~= -math.huge and value % 1 == 0
end

---Creates one run-owned unit-position controller and prearms cleanup.
---@param dependencies table
---@return table
function M.new(dependencies)
    assert(type(dependencies) == 'table',
        'unit position controller requires dependencies')
    local adapter = assert(dependencies.adapter,
        'unit position controller requires adapter')
    local register_cleanup = assert(dependencies.register_cleanup,
        'unit position controller requires cleanup registration')
    assert(type(register_cleanup) == 'function',
        'unit position cleanup registration must be a function')
    local controller = {
        baselines={}, ownership_order={}, cleanup_registered=false,
    }

    ---Prearms position restoration for the current ownership cycle.
    function controller:ensure_cleanup()
        if self.cleanup_registered then return end
        register_cleanup('restore DwarfSpec-owned unit positions', function()
            self.cleanup_registered = false
            self:restore_all()
        end)
        self.cleanup_registered = true
    end

    ---Moves one resolved unit and records its first successful baseline.
    ---@param unit_id integer
    ---@param position table
    ---@return boolean
    function controller:move(unit_id, position)
        assert(is_integer(unit_id), 'unit id must be an integer')
        local destination = adapter:normalize_position(position)
        assert(destination ~= nil,
            'unit position must identify a valid loaded map tile')
        local unit = adapter:resolve(unit_id)
        assert(unit ~= nil, 'unit id does not resolve to a valid unit')
        local baseline = self.baselines[unit_id]
        local provisional
        if baseline == nil then
            self:ensure_cleanup()
            provisional = adapter:capture_baseline(unit)
            if provisional == nil then return false end
        end
        local moved, receipt = adapter:teleport(unit, destination)
        if not moved then return false end
        assert(type(receipt) == 'table',
            'unit position adapter did not return an occupancy receipt')
        if baseline == nil then
            provisional.last_arrival = receipt
            self.baselines[unit_id] = provisional
            self.ownership_order[#self.ownership_order + 1] = unit_id
        else
            baseline.last_arrival = receipt
        end
        return true
    end

    ---Restores all owned units in reverse ownership order.
    function controller:restore_all()
        local failures = {}
        for index = #self.ownership_order, 1, -1 do
            local unit_id = self.ownership_order[index]
            local baseline = self.baselines[unit_id]
            local unit = adapter:resolve(unit_id)
            local ok, failure = pcall(function()
                adapter:restore(unit, baseline)
            end)
            if ok then
                self.baselines[unit_id] = nil
                table.remove(self.ownership_order, index)
            else
                failures[#failures + 1] =
                    ('unit %d: %s'):format(unit_id, tostring(failure))
            end
        end
        assert(#failures == 0,
            'DwarfSpec unit position cleanup failed: ' ..
                table.concat(failures, '; '))
    end

    ---Returns authoritative coordinate ownership for cleanup verification.
    ---@return table
    function controller:cleanup_state()
        return {
            unit_position_active=#self.ownership_order > 0,
            owned_position_count=#self.ownership_order,
        }
    end

    return controller
end

return M
