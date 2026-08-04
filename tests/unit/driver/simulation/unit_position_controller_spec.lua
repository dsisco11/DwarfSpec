local module = require('dwarfspec.driver.simulation.unit_position_controller')

describe('driver unit position controller', function()
    ---Creates an observable shared-position controller fixture.
    ---@return table, table
    local function fixture()
        local state = {
            units={}, moves={}, restores={}, cleanups={}, fail_move=false,
            fail_restore={}, valid=true,
        }
        local adapter = {}
        ---Resolves one fixture unit.
        ---@param id integer
        ---@return table|nil
        function adapter:resolve(id) return state.units[id] end
        ---Copies one fixture position when it is valid.
        ---@param position table
        ---@return table|nil
        function adapter:normalize_position(position)
            if not state.valid or type(position) ~= 'table' or
                    type(position.x) ~= 'number' or position.x % 1 ~= 0 or
                    type(position.y) ~= 'number' or position.y % 1 ~= 0 or
                    type(position.z) ~= 'number' or position.z % 1 ~= 0 then
                return nil
            end
            return {x=position.x, y=position.y, z=position.z}
        end
        ---Captures the fixture unit baseline.
        ---@param unit table
        ---@return table
        function adapter:capture_baseline(unit)
            return {position={x=unit.pos.x, y=unit.pos.y, z=unit.pos.z},
                idle_area={x=unit.idle_area.x, y=unit.idle_area.y,
                    z=unit.idle_area.z}, on_ground=unit.on_ground}
        end
        ---Moves one fixture unit.
        ---@param unit table
        ---@param destination table
        ---@return boolean
        function adapter:teleport(unit, destination)
            state.moves[#state.moves + 1] = {unit=unit.id,
                destination={x=destination.x, y=destination.y, z=destination.z}}
            if state.fail_move then return false end
            local receipt = {position={x=destination.x, y=destination.y,
                z=destination.z}, occupancy={unit=false, unit_grounded=false}}
            unit.pos = {x=destination.x, y=destination.y, z=destination.z}
            unit.idle_area = {x=destination.x, y=destination.y, z=destination.z}
            return true, receipt
        end
        ---Restores one fixture unit or raises its configured failure.
        ---@param unit table|nil
        ---@param baseline table
        function adapter:restore(unit, baseline)
            assert(unit ~= nil, 'unit unavailable')
            assert(not state.fail_restore[unit.id], 'restore rejected')
            state.restores[#state.restores + 1] = unit.id
            unit.pos = baseline.position
            unit.idle_area = baseline.idle_area
        end
        local controller = module.new({adapter=adapter,
            register_cleanup=function(name, callback)
                state.cleanups[#state.cleanups + 1] = {name=name, callback=callback}
            end})
        return state, controller
    end

    ---Creates one movable fixture unit.
    ---@param id integer
    ---@return table
    local function unit(id)
        return {id=id, pos={x=id, y=1, z=2},
            idle_area={x=id, y=1, z=2}, on_ground=false}
    end

    it('prearms cleanup and owns only a successful first move', function()
        local state, controller = fixture()
        state.units[4] = unit(4)
        assert.equals(0, #state.cleanups)
        assert.is_false(controller:cleanup_state().unit_position_active)
        state.fail_move = true
        assert.is_false(controller:move(4, {x=8, y=9, z=2}))
        assert.equals(1, #state.cleanups)
        assert.is_false(controller:cleanup_state().unit_position_active)
        state.fail_move = false
        assert.is_true(controller:move(4, {x=8, y=9, z=2}))
        assert.is_true(controller:cleanup_state().unit_position_active)
        assert.equals(1, controller:cleanup_state().owned_position_count)
    end)

    it('rearms cleanup after a completed ownership cycle', function()
        local state, controller = fixture()
        state.units[4] = unit(4)
        assert.is_true(controller:move(4, {x=8, y=9, z=2}))
        state.cleanups[1].callback()
        assert.is_true(controller:move(4, {x=12, y=13, z=2}))
        assert.equals(2, #state.cleanups)
        state.cleanups[2].callback()
        assert.same({4, 4}, state.restores)
        assert.same({x=4, y=1, z=2}, state.units[4].pos)
    end)

    it('retains one baseline across explicit and job-travel moves', function()
        local state, controller = fixture()
        state.units[4] = unit(4)
        controller:move(4, {x=8, y=9, z=2})
        controller:move(4, {x=12, y=13, z=2})
        state.cleanups[1].callback()
        assert.same({4}, state.restores)
        assert.same({x=4, y=1, z=2}, state.units[4].pos)
        assert.is_false(controller:cleanup_state().unit_position_active)
    end)

    it('restores in reverse ownership order', function()
        local state, controller = fixture()
        state.units[2] = unit(2)
        state.units[7] = unit(7)
        controller:move(2, {x=20, y=1, z=2})
        controller:move(7, {x=70, y=1, z=2})
        controller:restore_all()
        assert.same({7, 2}, state.restores)
    end)

    it('retains failed restoration ownership and restores other units', function()
        local state, controller = fixture()
        state.units[2] = unit(2)
        state.units[7] = unit(7)
        controller:move(2, {x=20, y=1, z=2})
        controller:move(7, {x=70, y=1, z=2})
        state.fail_restore[7] = true
        local ok, failure = pcall(function() controller:restore_all() end)
        assert.is_false(ok)
        assert.matches('unit 7', failure, 1, true)
        assert.same({2}, state.restores)
        assert.equals(1, controller:cleanup_state().owned_position_count)
    end)

    it('validates ids, units, and copied loaded-map positions', function()
        local state, controller = fixture()
        state.units[1] = unit(1)
        assert.has_error(function() controller:move(1.5, {x=1, y=2, z=3}) end,
            'unit id must be an integer')
        assert.has_error(function() controller:move(8, {x=1, y=2, z=3}) end,
            'unit id does not resolve to a valid unit')
        state.valid = false
        assert.has_error(function() controller:move(1, {x=1, y=2, z=3}) end,
            'unit position must identify a valid loaded map tile')
    end)

    it('prearmed LIFO cleanup restores only after recurring cancellation',
            function()
        for _, move_before_speed in ipairs({true, false}) do
            local state, controller = fixture()
            state.units[1] = unit(1)
            local order = {}
            if move_before_speed then
                controller:move(1, {x=9, y=2, z=3})
            else
                controller:ensure_cleanup()
            end
            state.cleanups[#state.cleanups + 1] = {
                name='recurring', callback=function()
                    order[#order + 1] = 'cancel recurring'
                end,
            }
            if not move_before_speed then
                controller:move(1, {x=9, y=2, z=3})
            end
            local restore = state.cleanups[1].callback
            state.cleanups[1].callback = function()
                order[#order + 1] = 'restore positions'
                restore()
            end
            for index = #state.cleanups, 1, -1 do
                state.cleanups[index].callback()
            end
            assert.same({'cancel recurring', 'restore positions'}, order)
        end
    end)
end)
