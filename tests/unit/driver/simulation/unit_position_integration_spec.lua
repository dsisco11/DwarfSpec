local position_module =
    require('dwarfspec.driver.simulation.unit_position_controller')
local runtime_module =
    require('dwarfspec.driver.runtime.unit_position_runtime')
local travel_module = require('dwarfspec.driver.simulation.unit_job_travel')

describe('shared unit position integration', function()
    it('shares one adapter and first baseline across explicit and job moves',
            function()
        local unit = {
            id=6, pos={x=1, y=1, z=1}, idle_area={x=1, y=1, z=1},
            path={dest={x=9, y=9, z=1}, path={x={}, y={}, z={}}},
            relationship_ids={dragger=-1, draggee=-1}, following=0,
            counters={unconscious=0}, job={current_job={}},
        }
        local cleanups = {}
        local teleports = {}
        local adapter = {}
        ---Resolves the shared fixture unit.
        ---@param id integer
        ---@return table|nil
        function adapter:resolve(id) return id == unit.id and unit or nil end
        ---Copies a fixture destination.
        ---@param position table
        ---@return table
        function adapter:normalize_position(position)
            return {x=position.x, y=position.y, z=position.z}
        end
        ---Captures the original fixture coordinate.
        ---@return table
        function adapter:capture_baseline()
            return {position={x=unit.pos.x, y=unit.pos.y, z=unit.pos.z},
                idle_area={x=unit.idle_area.x, y=unit.idle_area.y,
                    z=unit.idle_area.z}, on_ground=false,
                occupancy={unit=true, unit_grounded=false}}
        end
        ---Records one shared-adapter teleport.
        ---@param target table
        ---@param destination table
        ---@return boolean
        function adapter:teleport(target, destination)
            teleports[#teleports + 1] = {x=destination.x, y=destination.y,
                z=destination.z}
            target.pos = {x=destination.x, y=destination.y, z=destination.z}
            target.idle_area = {x=destination.x, y=destination.y,
                z=destination.z}
            return true, {position={x=destination.x, y=destination.y,
                z=destination.z}, occupancy={unit=false, unit_grounded=false}}
        end
        ---Restores the shared first baseline.
        ---@param target table
        ---@param baseline table
        function adapter:restore(target, baseline)
            target.pos = baseline.position
            target.idle_area = baseline.idle_area
        end
        ---Preflights one fixture move.
        ---@param id integer
        ---@param destination table
        ---@return table
        function adapter:prepare(id, destination)
            return {unit_id=id, destination=destination,
                baseline=self:capture_baseline(),
                destination_occupancy={unit=false, unit_grounded=false}}
        end
        ---Applies one fixture readiness snapshot.
        ---@param readiness table
        ---@return boolean, table
        function adapter:apply(readiness)
            local moved, arrival = self:teleport(unit, readiness.destination)
            return moved, {unit_id=readiness.unit_id,
                baseline=readiness.baseline,
                destination=readiness.destination, arrival=arrival}
        end
        ---Returns the current fixture observation.
        ---@return table
        function adapter:observe()
            return {position=unit.pos, idle_area=unit.idle_area,
                on_ground=false,
                occupancy={unit=true, unit_grounded=false}}
        end
        ---Returns both endpoint occupancies for a fixture move.
        ---@return table
        function adapter:observe_transition()
            return {unit=self:observe(),
                source={unit=false, unit_grounded=false},
                destination={unit=true, unit_grounded=false}}
        end
        ---Restores one fixture receipt.
        ---@param receipt table
        function adapter:restore_receipt(receipt)
            self:restore(unit, receipt.baseline)
        end
        local positions = position_module.new({adapter=adapter,
            register_cleanup=function(_, callback)
                cleanups[#cleanups + 1] = callback
            end})
        local runtime = runtime_module.new(adapter)
        local travel = travel_module.new({
            resolve_unit=function() return unit end,
            is_valid_position=function() return true end,
            can_walk_between=function() return true end,
            is_tile_visible=function() return true end,
            dragger_relationship='dragger', draggee_relationship='draggee',
            resize_vector=function() end,
            position_controller=positions,
        })

        local readiness = runtime:prepare(6, {x=4, y=4, z=1})
        local moved, receipt = runtime:apply(readiness)
        assert.is_true(moved)
        assert.is_true(travel:attempt(6))
        assert.equals(1, positions:cleanup_state().owned_position_count)
        assert.same({{x=4, y=4, z=1}, {x=9, y=9, z=1}}, teleports)
        cleanups[1]()
        runtime:restore(receipt)
        assert.same({x=1, y=1, z=1}, unit.pos)
    end)
end)
