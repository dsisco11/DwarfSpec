local cleanup = require('dwarfspec.host.execution.cleanup')
local position_module =
    require('dwarfspec.driver.simulation.unit_position_controller')
local recurring_module =
    require('dwarfspec.driver.simulation.recurring_operation')
local speed_module =
    require('dwarfspec.driver.simulation.unit_speed_controller')

describe('shared unit position cleanup routes', function()
    it('cancels recurring ownership before restoration on every terminal route',
            function()
        for index, route in ipairs({
            'success', 'assertion failure', 'timeout', 'abort', 'callback fault',
        }) do
            local registry = cleanup.new({})
            local order = {}
            local callbacks = {}
            local active = {}
            local reports = 0
            local unit = {id=3, pos={x=1, y=1, z=1},
                idle_area={x=1, y=1, z=1}}
            local function register(name, callback)
                cleanup.push(registry, name, function()
                    if name == 'unit speed recurring operation' then
                        order[#order + 1] = 'cancel recurring'
                    elseif name == 'restore DwarfSpec-owned unit positions' then
                        order[#order + 1] = 'restore positions'
                    end
                    callback()
                end)
            end
            local positions = position_module.new({
                adapter={
                    resolve=function(_, id) return id == 3 and unit or nil end,
                    normalize_position=function(_, value)
                        return {x=value.x, y=value.y, z=value.z}
                    end,
                    capture_baseline=function()
                        return {position={x=1, y=1, z=1},
                            idle_area={x=1, y=1, z=1}, on_ground=false,
                            occupancy={unit=true, unit_grounded=false}}
                    end,
                    teleport=function(_, target, destination)
                        target.pos = {x=destination.x, y=destination.y,
                            z=destination.z}
                        return true, {position=destination,
                            occupancy={unit=false, unit_grounded=false}}
                    end,
                    restore=function(_, target, baseline)
                        target.pos = baseline.position
                    end,
                },
                register_cleanup=register,
            })
            local recurring = recurring_module.new({
                schedule=function(callback)
                    local handle = #callbacks + 1
                    callbacks[handle] = callback
                    active[handle] = true
                    return handle
                end,
                cancel=function(handle) active[handle] = nil end,
                is_scheduled=function(handle) return active[handle] == true end,
                report_failure=function() reports = reports + 1 end,
                register_cleanup=register,
            })
            local move_first = index % 2 == 1
            if move_first then positions:move(3, {x=4, y=4, z=1}) end
            local speed = speed_module.new({
                recurring=recurring,
                targets={
                    assert_ready=function() end,
                    capture_default_ids=function() return {3} end,
                    for_each_available=function(_, _, callback)
                        callback(unit, 3)
                        return true
                    end,
                },
                actions={accelerate=function() end},
                job_travel={attempt=function()
                    if route == 'callback fault' then
                        error('position adapter invariant')
                    end
                    return false
                end},
                register_cleanup=register,
            })
            speed:activate({teleport_jobs=true})
            if not move_first then positions:move(3, {x=4, y=4, z=1}) end
            if route == 'callback fault' then
                active[1] = nil
                callbacks[1]()
            end

            assert.is_true(cleanup.run(registry, route))
            assert.same({'cancel recurring', 'restore positions'}, order)
            assert.is_false(recurring:cleanup_state().unit_speed_active)
            assert.is_false(positions:cleanup_state().unit_position_active)
            assert.equals(route == 'callback fault' and 1 or 0, reports)
        end
    end)
end)
