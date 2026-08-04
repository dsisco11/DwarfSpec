-- Controlled native fixture helpers for unit-speed live qualification.

local M = {}

local expected_save = 'TestWorld 01'

---Returns a copied native coordinate.
---@param position any
---@return table
local function copy_position(position)
    return {x=position.x, y=position.y, z=position.z}
end

---Returns whether two coordinates are equal.
---@param left any
---@param right any
---@return boolean
function M.positions_equal(left, right)
    return left.x == right.x and left.y == right.y and left.z == right.z
end

---Returns native occupancy for one loaded-map coordinate.
---@param position any
---@return any
local function occupancy(position)
    local block = dfhack.maps.getTileBlock(position)
    if block == nil then return nil end
    return block.occupancy[position.x % 16][position.y % 16]
end

---Returns whether one unit is safe for reversible explicit positioning.
---@param unit any
---@return boolean
local function position_safe(unit)
    if unit == nil or not dfhack.maps.isValidTilePos(unit.pos) or
            unit.flags1.projectile or unit.flags1.rider or
            unit.flags1.ridden or
            unit.relationship_ids[df.unit_relationship_type.RiderMount] ~= -1 or
            dfhack.units.getGeneralRef(
                unit, df.general_ref_type.UNIT_RIDER) ~= nil then
        return false
    end
    local tile = occupancy(unit.pos)
    if tile == nil then return false end
    return unit.flags1.on_ground and tile.unit_grounded or
        not unit.flags1.on_ground and tile.unit
end

---Asserts that the explicitly controlled disposable fortress is loaded.
function M.assert_controlled_world()
    assert(dfhack.isWorldLoaded() and dfhack.isMapLoaded() and
            dfhack.world.isFortressMode(),
        'unit-speed live fixture requires a loaded fortress map')
    assert(expected_save == dfhack.world.ReadWorldFolder(),
        'unit-speed live fixture refuses to mutate an unrecognized save')
    assert(df.global.pause_state,
        'unit-speed live fixture must begin with simulation paused')
    assert(not df.global.debug_turbospeed,
        'unit-speed live fixture requires native turbo speed disabled')
end

---Returns one unit by stable id and validates reversible position state.
---@param unit_id integer
---@return any
function M.unit(unit_id)
    local unit = df.unit.find(unit_id)
    assert(unit and position_safe(unit),
        'unit-speed fixture unit is unavailable or position-unsafe: ' ..
            tostring(unit_id))
    return unit
end

---Returns the deterministic first valid noncitizen unit.
---@return any
function M.noncitizen()
    local candidates = {}
    for _, unit in ipairs(df.global.world.units.active) do
        if dfhack.units.isActive(unit) and dfhack.units.isAlive(unit) and
                not dfhack.units.isCitizen(unit, false) and
                not dfhack.units.isResident(unit, false) and
                position_safe(unit) then
            candidates[#candidates + 1] = unit
        end
    end
    table.sort(candidates, function(left, right) return left.id < right.id end)
    return assert(candidates[1],
        'unit-speed fixture requires one valid noncitizen')
end

---Returns deterministic empty adjacent destinations for one unit.
---@param unit any
---@param count integer
---@return table[]
function M.destinations(unit, count)
    local positions = {}
    for dx = -1, 1 do
        for dy = -1, 1 do
            if dx ~= 0 or dy ~= 0 then
                local position = {
                    x=unit.pos.x + dx,
                    y=unit.pos.y + dy,
                    z=unit.pos.z,
                }
                local tile = occupancy(position)
                if dfhack.maps.isValidTilePos(position) and tile and
                        not tile.unit and not tile.unit_grounded and
                        dfhack.maps.canWalkBetween(unit.pos, position) and
                        dfhack.maps.isTileVisible(position) then
                    positions[#positions + 1] = position
                end
            end
        end
    end
    assert(#positions >= count,
        ('unit-speed fixture unit %d has only %d safe destinations')
            :format(unit.id, #positions))
    local selected = {}
    for index = 1, count do selected[index] = positions[index] end
    return selected
end

---Returns the positive timer and setter for one supported Job action.
---@param unit any
---@return integer, fun(value:integer)
function M.job_action_timer(unit)
    for _, action in ipairs(unit.actions) do
        if action.type == df.unit_action_type.Job and
                action.data.job.timer > 0 then
            return action.data.job.timer, function(value)
                action.data.job.timer = value
            end
        end
    end
    error('unit-speed fixture requires a positive Job action for unit ' ..
        tostring(unit.id), 2)
end

---Returns stable accessors for one existing supported Job action.
---@param restoration table
---@param unit any
---@return fun():integer|nil, fun(value:integer)
function M.organic_job_action(restoration, unit)
    for _, action in ipairs(unit.actions) do
        if action.type == df.unit_action_type.Job and
                action.data.job.timer > 0 then
            local action_id = action.id
            local original_timer = action.data.job.timer
            local function find_action()
                for _, candidate in ipairs(unit.actions) do
                    if candidate.id == action_id and
                            candidate.type == df.unit_action_type.Job then
                        return candidate
                    end
                end
                return nil
            end
            M.prearm(restoration, function()
                local current = find_action()
                if current then current.data.job.timer = original_timer end
            end)
            return function()
                local current = find_action()
                return current and current.data.job.timer or nil
            end, function(value)
                local current = assert(find_action(),
                    'organic Job action is no longer present')
                current.data.job.timer = value
            end
        end
    end
    error('unit-speed fixture requires a positive Job action for unit ' ..
        tostring(unit.id), 2)
end

---Adds a disposable Job action and returns its current timer reader.
---@param restoration table
---@param unit any
---@param timer integer
---@return fun():integer|nil, fun(value:integer)
function M.add_temporary_job_action(restoration, unit, timer)
    local action = df.unit_action:new()
    action.type = df.unit_action_type.Job
    action.data.job.timer = timer
    local insertion_completed = false
    M.prearm(restoration, function()
        for index, candidate in ipairs(unit.actions) do
            if candidate == action then
                unit.actions:erase(index)
                action:delete()
                return
            end
        end
        if not insertion_completed then action:delete() end
    end)
    unit.actions:insert('#', action)
    insertion_completed = true
    local function read_timer()
        for _, candidate in ipairs(unit.actions) do
            if candidate == action then return candidate.data.job.timer end
        end
        return nil
    end
    local function write_timer(value)
        for _, candidate in ipairs(unit.actions) do
            if candidate == action then
                candidate.data.job.timer = value
                return
            end
        end
        error('temporary unit action is no longer present', 2)
    end
    return read_timer, write_timer
end

---Creates an empty restoration stack for fixture-owned native mutations.
---@return table
function M.new_restoration()
    return {entries={}}
end

---Prearms one restoration callback before its associated mutation.
---@param restoration table
---@param callback function
function M.prearm(restoration, callback)
    assert(type(callback) == 'function',
        'unit-speed fixture restoration must be callable')
    restoration.entries[#restoration.entries + 1] = callback
end

---Restores every fixture-owned mutation in reverse order.
---@param restoration table
function M.restore_all(restoration)
    local failures = {}
    for index = #restoration.entries, 1, -1 do
        local ok, failure = xpcall(restoration.entries[index], debug.traceback)
        if not ok then failures[#failures + 1] = tostring(failure) end
        restoration.entries[index] = nil
    end
    assert(#failures == 0, table.concat(failures, '\n'))
end

---Owns and sets one action timer until fixture restoration.
---@param restoration table
---@param read_timer fun():integer
---@param write_timer fun(value:integer)
---@param value integer
function M.set_timer(restoration, read_timer, write_timer, value)
    local original = read_timer()
    M.prearm(restoration, function()
        write_timer(original)
        assert(original == read_timer(),
            'unit-speed fixture failed to restore the action timer')
    end)
    write_timer(value)
end

---Owns and changes one unit's remaining path and destination.
---@param restoration table
---@param unit any
---@param destination table
function M.set_job_destination(restoration, unit, destination)
    local original = copy_position(unit.path.dest)
    local path = unit.path.path
    local original_lengths = {#path.x, #path.y, #path.z}
    assert(original_lengths[1] == 0 and original_lengths[2] == 0 and
            original_lengths[3] == 0,
        'unit-speed fixture requires initially empty native path vectors')
    M.prearm(restoration, function()
        unit.path.dest.x = original.x
        unit.path.dest.y = original.y
        unit.path.dest.z = original.z
        path.x:resize(0)
        path.y:resize(0)
        path.z:resize(0)
        assert(M.positions_equal(original, unit.path.dest),
            'unit-speed fixture failed to restore the job destination')
    end)
    unit.path.dest.x = destination.x
    unit.path.dest.y = destination.y
    unit.path.dest.z = destination.z
    path.x:resize(1)
    path.y:resize(1)
    path.z:resize(1)
    path.x[0] = destination.x
    path.y[0] = destination.y
    path.z[0] = destination.z
end

---Owns and changes one unit's inactive flag.
---@param restoration table
---@param unit any
---@param inactive boolean
function M.set_inactive(restoration, unit, inactive)
    local original = unit.flags1.inactive
    M.prearm(restoration, function()
        unit.flags1.inactive = original
        assert(original == unit.flags1.inactive,
            'unit-speed fixture failed to restore the inactive flag')
    end)
    unit.flags1.inactive = inactive
end

---Owns a temporary current-job object for one otherwise idle unit.
---@param restoration table
---@param unit any
function M.ensure_current_job(restoration, unit)
    if unit.job.current_job ~= nil then return end
    local job = df.job:new()
    M.prearm(restoration, function()
        unit.job.current_job = nil
        job:delete()
        assert(unit.job.current_job == nil,
            'unit-speed fixture failed to clear the temporary job')
    end)
    unit.job.current_job = job
end

return M
