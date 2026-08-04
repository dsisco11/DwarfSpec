-- Focused native qualification for run-owned unit speed and positioning.

local fixture = require('tests.automation.support.unit_speed_fixture')

local restored_positions = {}

---Returns a copied native coordinate.
---@param position any
---@return table
local function copy_position(position)
    return {x=position.x, y=position.y, z=position.z}
end

---Returns a copied sequence from one zero-based native vector.
---@param vector any
---@return table
local function copy_native_vector(vector)
    local copied = {}
    for index = 0, #vector - 1 do
        copied[#copied + 1] = vector[index]
    end
    return copied
end

---Returns copied remaining-path vectors for one unit.
---@param unit any
---@return table
local function copy_path(unit)
    return {
        x=copy_native_vector(unit.path.path.x),
        y=copy_native_vector(unit.path.path.y),
        z=copy_native_vector(unit.path.path.z),
    }
end

---Runs simulation only until one bounded native condition is satisfied.
---@param description string
---@param predicate fun():boolean
local function advance_until(description, predicate)
    ds.setGamePaused(false)
    local ok, failure = xpcall(function()
        ds.await(description, function()
            return predicate() and true or nil
        end, {timeout_ms=2000, frame_budget=180})
    end, debug.traceback)
    ds.setGamePaused(true)
    assert.is_true(ok, failure)
end

describe('unit speed controlled live fixture', function()
    local restoration

    setup(function()
        fixture.assert_controlled_world()
    end)

    before_each(function()
        fixture.assert_controlled_world()
        restoration = fixture.new_restoration()
    end)

    after_each(function()
        fixture.restore_all(restoration)
    end)

    it('01 positions a citizen and noncitizen synchronously while paused',
            function()
        local citizen = fixture.unit(68)
        local noncitizen = fixture.noncitizen()
        assert.is_true(dfhack.units.isCitizen(citizen, false))
        assert.is_false(dfhack.units.isCitizen(noncitizen, false))
        local citizen_destination = fixture.destinations(citizen, 1)[1]
        local noncitizen_destination = fixture.destinations(noncitizen, 1)[1]
        local tick = ds.getTick()
        local tps = ds.getGameSpeed()
        restored_positions[citizen.id] = copy_position(citizen.pos)
        restored_positions[noncitizen.id] = copy_position(noncitizen.pos)
        local citizen_job = citizen.job.current_job
        local noncitizen_job = noncitizen.job.current_job
        local citizen_path = copy_position(citizen.path.dest)
        local noncitizen_path = copy_position(noncitizen.path.dest)
        local citizen_remaining_path = copy_path(citizen)
        local noncitizen_remaining_path = copy_path(noncitizen)

        assert.is_nil(ds.setUnitPos(citizen.id, citizen_destination))
        assert.is_nil(ds.setUnitPos(noncitizen.id, noncitizen_destination))
        assert.is_true(fixture.positions_equal(citizen_destination, citizen.pos))
        assert.is_true(fixture.positions_equal(
            noncitizen_destination, noncitizen.pos))
        assert.equals(tick, ds.getTick())
        assert.equals(tps, ds.getGameSpeed())
        assert.is_true(ds.isGamePaused())
        assert.equals(citizen_job, citizen.job.current_job)
        assert.equals(noncitizen_job, noncitizen.job.current_job)
        assert.is_true(fixture.positions_equal(citizen_path, citizen.path.dest))
        assert.is_true(fixture.positions_equal(
            noncitizen_path, noncitizen.path.dest))
        assert.same(citizen_remaining_path, copy_path(citizen))
        assert.same(noncitizen_remaining_path, copy_path(noncitizen))
        local cleanup = ds.current_run().unit_speed_cleanup_probe()
        assert.is_false(cleanup.unit_speed_active)
        assert.is_true(cleanup.unit_position_active)
        assert.equals(2, cleanup.owned_position_count)
    end)

    it('02 verifies explicit positions were restored by prior cleanup', function()
        for unit_id, expected in pairs(restored_positions) do
            assert.is_true(fixture.positions_equal(
                expected, fixture.unit(unit_id).pos))
        end
    end)

    it('03 accelerates one supported action without moving its unit', function()
        local unit = fixture.unit(72)
        local original_position = copy_position(unit.pos)
        local original_destination = copy_position(unit.path.dest)
        local read_timer, write_timer = fixture.organic_job_action(
            restoration, unit)
        local tps = ds.getGameSpeed()

        write_timer(10000)
        dfhack.units.setGroupActionTimers(
            unit, 1, df.unit_action_type_group.All)
        assert.equals(1, read_timer())
        write_timer(10000)

        assert.is_nil(ds.setUnitSpeed({
            fast_actions=true,
            unit_ids={unit.id},
        }))
        assert.is_true(ds.isGamePaused())
        assert.equals(10000, read_timer())
        advance_until('unit action timer acceleration', function()
            local timer = read_timer()
            return timer == nil or timer <= 1
        end)
        local accelerated_timer = read_timer()
        assert.is_true(accelerated_timer == nil or accelerated_timer <= 1)
        assert.is_true(fixture.positions_equal(original_position, unit.pos))
        assert.is_true(fixture.positions_equal(
            original_destination, unit.path.dest))
        assert.equals(tps, ds.getGameSpeed())
        assert.is_false(df.global.debug_turbospeed)
    end)

    it('04 teleports only an explicit target and leaves actions unaccelerated',
            function()
        local target = fixture.unit(72)
        local control = fixture.unit(73)
        fixture.ensure_current_job(restoration, control)
        local target_destination = fixture.destinations(target, 1)[1]
        local control_destination = fixture.destinations(control, 1)[1]
        local control_original = copy_position(control.pos)
        fixture.set_job_destination(restoration, target, target_destination)
        fixture.set_job_destination(restoration, control, control_destination)
        local read_timer = fixture.add_temporary_job_action(
            restoration, target, 10000)

        assert.is_nil(ds.setUnitSpeed({
            teleport_jobs=true,
            unit_ids={target.id},
        }))
        advance_until('explicit target job teleport', function()
            return fixture.positions_equal(target_destination, target.pos)
        end)
        assert.is_true(fixture.positions_equal(target_destination, target.pos))
        assert.equals(0, #target.path.path.x)
        assert.equals(0, #target.path.path.y)
        assert.equals(0, #target.path.path.z)
        assert.is_true(fixture.positions_equal(control_original, control.pos))
        assert.equals(1,
            ds.current_run().unit_speed_cleanup_probe().owned_position_count)
        assert.is_true(read_timer() ~= nil and read_timer() > 1)
    end)

    it('05 retains one baseline across explicit and job-travel moves', function()
        local unit = fixture.unit(72)
        local original = copy_position(unit.pos)
        local explicit_destination = fixture.destinations(unit, 1)[1]
        assert.is_nil(ds.setUnitPos(unit.id, explicit_destination))
        local job_destination = fixture.destinations(unit, 1)[1]
        fixture.set_job_destination(restoration, unit, job_destination)
        restored_positions[unit.id] = original

        assert.is_nil(ds.setUnitSpeed({
            teleport_jobs=true,
            unit_ids={unit.id},
        }))
        advance_until('shared-baseline job teleport', function()
            return fixture.positions_equal(job_destination, unit.pos)
        end)
        assert.is_true(fixture.positions_equal(job_destination, unit.pos))
        assert.equals(1,
            ds.current_run().unit_speed_cleanup_probe().owned_position_count)
    end)

    it('06 verifies the shared first baseline was restored', function()
        assert.is_true(fixture.positions_equal(
            restored_positions[72], fixture.unit(72).pos))
    end)

    it('07 omits a unit that becomes eligible after activation', function()
        local target = fixture.unit(72)
        local later = fixture.unit(74)
        fixture.ensure_current_job(restoration, later)
        local target_destination = fixture.destinations(target, 1)[1]
        local later_destination = fixture.destinations(later, 1)[1]
        local later_original = copy_position(later.pos)
        fixture.set_job_destination(restoration, target, target_destination)
        fixture.set_job_destination(restoration, later, later_destination)
        fixture.set_inactive(restoration, later, true)

        assert.is_nil(ds.setUnitSpeed({teleport_jobs=true}))
        later.flags1.inactive = false
        advance_until('default snapshot target teleport', function()
            return fixture.positions_equal(target_destination, target.pos)
        end)
        assert.is_true(fixture.positions_equal(target_destination, target.pos))
        assert.is_true(fixture.positions_equal(later_original, later.pos))
    end)
end)
