-- Game-state command bindings for one DwarfSpec run.

local M = {}

---Returns whether a value is a finite Lua number.
---@param value any
---@return boolean
local function is_finite_number(value)
    return type(value) == 'number' and value == value and
        value ~= math.huge and value ~= -math.huge
end

---Binds game-state commands to the public run-scoped namespace.
---@param ds table
---@param dependencies table
function M.bind(ds, dependencies)
    local context = dependencies.context
    local cleanup_module = dependencies.cleanup_module
    local cleanup_registry = dependencies.cleanup_registry
    local function ratio_matches(actual, expected)
        if not is_finite_number(actual) or not is_finite_number(expected) then
            return false
        end
        return math.abs(actual - expected) <= 1e-6 *
            math.max(1, math.abs(expected))
    end
    local function speed_state()
        local enabler = context.get_game_enabler()
        assert(enabler ~= nil,
            'DwarfSpec setGameSpeed requires df.global.enabler')
        assert(is_finite_number(enabler.fps) and enabler.fps >= 1 and
            enabler.fps % 1 == 0,
            'DwarfSpec setGameSpeed requires a valid positive integer df.global.enabler.fps')
        assert(is_finite_number(enabler.gfps) and enabler.gfps > 0,
            'DwarfSpec setGameSpeed requires a valid positive df.global.enabler.gfps')
        assert(is_finite_number(enabler.fps_per_gfps),
            'DwarfSpec setGameSpeed requires a valid df.global.enabler.fps_per_gfps')
        return enabler, enabler.fps, enabler.gfps, enabler.fps_per_gfps
    end

    ---Returns whether the Dwarf Fortress simulation is currently paused.
    ---@return boolean
    function ds.isGamePaused()
        local pause_state = df and df.global and df.global.pause_state
        assert(type(pause_state) == 'boolean',
            'DwarfSpec isGamePaused requires a valid df.global.pause_state')
        return pause_state
    end

    ---Sets game pause state and registers restoration once per example.
    ---@param paused boolean
---@return boolean
    function ds.setGamePaused(paused)
        assert(type(paused) == 'boolean', 'game pause state must be a boolean')
        if context.game_pause_cleanup_entry == nil then
            local original = ds.isGamePaused()
            context.game_pause_cleanup_entry = cleanup_module.push(
                cleanup_registry, 'restore game pause state', function()
                    local global = df and df.global
                    assert(global, 'DwarfSpec could not restore game pause state: df.global is unavailable')
                    global.pause_state = original
                    assert(global.pause_state == original,
                        'DFHack rejected the original game pause state')
                    context.game_pause_cleanup_entry = nil
                end)
        end
        local global = df and df.global
        assert(global, 'DwarfSpec could not set game pause state: df.global is unavailable')
        global.pause_state = paused
        assert(global.pause_state == paused, 'DFHack rejected the requested game pause state')
        return paused
    end

    ---Sets process-global native turbo speed and registers restoration once.
    ---@param enabled boolean
    ---@return boolean
    function ds.setTurboSpeed(enabled)
        assert(type(enabled) == 'boolean',
            'turbo speed state must be a boolean')
        local global = df and df.global
        assert(global and type(global.debug_turbospeed) == 'boolean',
            'DwarfSpec setTurboSpeed requires a valid ' ..
                'df.global.debug_turbospeed')
        if context.turbo_speed_cleanup_entry == nil then
            local original = global.debug_turbospeed
            context.turbo_speed_cleanup_entry = cleanup_module.push(
                cleanup_registry, 'restore native turbo speed', function()
                    local current = df and df.global
                    assert(current and
                            type(current.debug_turbospeed) == 'boolean',
                        'DwarfSpec could not restore native turbo speed: ' ..
                            'df.global.debug_turbospeed is unavailable')
                    current.debug_turbospeed = original
                    assert(current.debug_turbospeed == original,
                        'DFHack rejected the original native turbo speed')
                    context.turbo_speed_cleanup_entry = nil
                end)
        end
        global.debug_turbospeed = enabled
        assert(global.debug_turbospeed == enabled,
            'DFHack rejected the requested native turbo speed')
        return enabled
    end

    ---Returns the current game ticks-per-second target.
    ---@return integer
    function ds.getGameSpeed()
        local enabler = context.get_game_enabler()
        assert(enabler ~= nil,
            'DwarfSpec getGameSpeed requires df.global.enabler')
        assert(is_finite_number(enabler.fps) and enabler.fps >= 1 and
            enabler.fps % 1 == 0,
            'DwarfSpec getGameSpeed requires a valid positive integer df.global.enabler.fps')
        return enabler.fps
    end

    ---Sets game ticks per second and registers restoration once per example.
    ---@param tps integer
    ---@return integer
    function ds.setGameSpeed(tps)
        assert(is_finite_number(tps) and tps >= 1 and tps % 1 == 0,
            'game speed must be a positive integer TPS target')
        local enabler, original_tps, graphical_rate, original_ratio = speed_state()
        if context.game_speed_cleanup_entry == nil then
            context.game_speed_cleanup_entry = cleanup_module.push(cleanup_registry,
                'restore game speed', function()
                    local current = context.get_game_enabler()
                    assert(current, 'DwarfSpec could not restore game speed: df.global.enabler is unavailable')
                    local restored = context.set_game_speed(current, original_tps, original_ratio)
                    assert(restored ~= false, 'DFHack rejected the original game speed')
                    assert(current.fps == original_tps and current.fps_per_gfps == original_ratio,
                        'DFHack did not restore the original game speed')
                    context.game_speed_cleanup_entry = nil
                end)
        end
        local expected_ratio = tps / graphical_rate
        local ok, accepted = pcall(context.set_game_speed, enabler, tps, expected_ratio)
        assert(ok, 'DwarfSpec could not set game speed: ' .. tostring(accepted))
        assert(accepted ~= false, 'DFHack rejected the requested game speed')
        assert(enabler.fps == tps, 'DFHack did not apply the requested game TPS target')
        assert(ratio_matches(enabler.fps_per_gfps, expected_ratio),
            'DFHack did not apply the requested game speed ratio')
        return tps
    end

    ---Returns the current in-year simulation tick for the loaded world.
    ---@return integer
    function ds.getTick()
        local tick = df and df.global and df.global.cur_year_tick
        assert(type(tick) == 'number' and tick % 1 == 0 and tick >= 0,
            'DwarfSpec getTick requires a loaded world with a valid df.global.cur_year_tick')
        return tick
    end

    ---Returns DFHack's current millisecond clock value.
    ---@return integer
    function ds.getTime()
        local get_tick_count = dfhack and dfhack.getTickCount
        assert(type(get_tick_count) == 'function', 'DwarfSpec getTime requires dfhack.getTickCount')
        local time = get_tick_count()
        assert(type(time) == 'number' and time % 1 == 0 and time >= 0,
            'DFHack getTickCount did not return a valid millisecond clock')
        return time
    end

    ---Returns the directory name of the currently loaded save game.
    ---@return string
    function ds.getSaveDirectoryName()
        assert(dfhack and type(dfhack.isWorldLoaded) == 'function' and dfhack.isWorldLoaded(),
            'DwarfSpec getSaveDirectoryName requires a loaded save game')
        assert(type(dfhack.world) == 'table' and type(dfhack.world.ReadWorldFolder) == 'function',
            'DwarfSpec getSaveDirectoryName requires dfhack.world.ReadWorldFolder')
        local name = dfhack.world.ReadWorldFolder()
        assert(type(name) == 'string' and name ~= '',
            'DFHack ReadWorldFolder did not return a valid save directory name')
        return name
    end
end

return M
