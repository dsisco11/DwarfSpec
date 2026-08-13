-- Cohesive native game-state query capability.

---@class dwarfspec.GameQueryRuntime
---@field private _context table
---@field private _df table
---@field private _dfhack table
local GameQueryRuntime = {}
GameQueryRuntime.__index = GameQueryRuntime

---Creates the game-query runtime capability.
---@param options table
---@return dwarfspec.GameQueryRuntime
function GameQueryRuntime.new(options)
    assert(type(options) == 'table',
        'game-query runtime options are required')
    assert(type(options.context) == 'table',
        'game-query runtime requires the run context')
    return setmetatable({_context=options.context, _df=options.df,
        _dfhack=options.dfhack}, GameQueryRuntime)
end

---Returns whether the simulation is paused.
---@return boolean
function GameQueryRuntime:is_game_paused()
    local pause_state = self._df and self._df.global and
        self._df.global.pause_state
    assert(type(pause_state) == 'boolean',
        'DwarfSpec isGamePaused requires a valid df.global.pause_state')
    return pause_state
end

---Returns the current positive integer TPS target.
---@return integer
function GameQueryRuntime:get_game_speed()
    local enabler = self._context.get_game_enabler()
    assert(enabler ~= nil,
        'DwarfSpec getGameSpeed requires df.global.enabler')
    local tps = enabler.fps
    assert(type(tps) == 'number' and tps >= 1 and tps % 1 == 0,
        'DwarfSpec getGameSpeed requires a valid positive integer ' ..
            'df.global.enabler.fps')
    return tps
end

---Returns the current in-year simulation tick.
---@return integer
function GameQueryRuntime:get_tick()
    local tick = self._df and self._df.global and
        self._df.global.cur_year_tick
    assert(type(tick) == 'number' and tick % 1 == 0 and tick >= 0,
        'DwarfSpec getTick requires a loaded world with a valid ' ..
            'df.global.cur_year_tick')
    return tick
end

---Returns DFHack's millisecond clock.
---@return integer
function GameQueryRuntime:get_time()
    local operation = self._dfhack and self._dfhack.getTickCount
    assert(type(operation) == 'function',
        'DwarfSpec getTime requires dfhack.getTickCount')
    local value = operation()
    assert(type(value) == 'number' and value % 1 == 0 and value >= 0,
        'DFHack getTickCount did not return a valid millisecond clock')
    return value
end

---Returns the current save directory name.
---@return string
function GameQueryRuntime:get_save_directory_name()
    local is_loaded = self._dfhack and self._dfhack.isWorldLoaded
    assert(type(is_loaded) == 'function' and is_loaded(),
        'DwarfSpec getSaveDirectoryName requires a loaded save game')
    local world = self._dfhack.world
    assert(type(world) == 'table' and
            type(world.ReadWorldFolder) == 'function',
        'DwarfSpec getSaveDirectoryName requires ' ..
            'dfhack.world.ReadWorldFolder')
    local name = world.ReadWorldFolder()
    assert(type(name) == 'string' and name ~= '',
        'DFHack ReadWorldFolder did not return a valid save directory name')
    return name
end

---Returns whether the current focus matches one path.
---@param path string
---@return boolean
function GameQueryRuntime:has_focus(path)
    local gui = self._dfhack and self._dfhack.gui
    assert(type(gui) == 'table' and
            type(gui.matchFocusString) == 'function',
        'DwarfSpec hasFocus requires dfhack.gui.matchFocusString')
    local focused = gui.matchFocusString(path)
    assert(type(focused) == 'boolean',
        'DFHack matchFocusString did not return a boolean')
    return focused
end

return GameQueryRuntime
