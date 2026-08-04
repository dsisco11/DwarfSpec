local command_module = require('dwarfspec.driver.commands.unit_position')
local position_module =
    require('dwarfspec.driver.simulation.unit_position_controller')
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
        local positions = position_module.new({adapter=adapter,
            register_cleanup=function(_, callback)
                cleanups[#cleanups + 1] = callback
            end})
        local ds = {}
        command_module.bind(ds, {position_controller=positions})
        local travel = travel_module.new({
            resolve_unit=function() return unit end,
            is_valid_position=function() return true end,
            can_walk_between=function() return true end,
            is_tile_visible=function() return true end,
            dragger_relationship='dragger', draggee_relationship='draggee',
            resize_vector=function() end,
            position_controller=positions,
        })

        ds.setUnitPos(6, {x=4, y=4, z=1})
        assert.is_true(travel:attempt(6))
        assert.equals(1, positions:cleanup_state().owned_position_count)
        assert.same({{x=4, y=4, z=1}, {x=9, y=9, z=1}}, teleports)
        cleanups[1]()
        assert.same({x=1, y=1, z=1}, unit.pos)
    end)
end)
