-- Cohesive native game-state mutation and observation capability.

---@class dwarfspec.GameStateRuntime
---@field private _context table
---@field private _df table
local GameStateRuntime = {}
GameStateRuntime.__index = GameStateRuntime

---Returns whether a value is a finite Lua number.
---@param value any
---@return boolean
local function is_finite_number(value)
    return type(value) == 'number' and value == value and
        value ~= math.huge and value ~= -math.huge
end

---Creates the native game-state capability.
---@param options table
---@return dwarfspec.GameStateRuntime
function GameStateRuntime.new(options)
    assert(type(options) == 'table',
        'game-state runtime options are required')
    assert(type(options.context) == 'table',
        'game-state runtime requires context')
    assert(type(options.df) == 'table',
        'game-state runtime requires df')
    assert(type(options.context.get_game_enabler) == 'function',
        'game-state runtime requires get_game_enabler')
    assert(type(options.context.set_game_speed) == 'function',
        'game-state runtime requires set_game_speed')
    return setmetatable({_context=options.context, _df=options.df},
        GameStateRuntime)
end

---Returns the validated native pause state.
---@return boolean
function GameStateRuntime:pause_state()
    local value = self._df.global and self._df.global.pause_state
    assert(type(value) == 'boolean',
        'DwarfSpec setGamePaused requires a valid df.global.pause_state')
    return value
end

---Applies one native pause state.
---@param value boolean
---@return boolean
function GameStateRuntime:set_pause(value)
    local global = assert(self._df.global,
        'DwarfSpec could not set game pause state: df.global is unavailable')
    global.pause_state = value
    return global.pause_state == value
end

---Returns the validated native turbo-speed state.
---@return boolean
function GameStateRuntime:turbo_state()
    local global = self._df.global
    assert(global and type(global.debug_turbospeed) == 'boolean',
        'DwarfSpec setTurboSpeed requires a valid ' ..
            'df.global.debug_turbospeed')
    return global.debug_turbospeed
end

---Applies one native turbo-speed state.
---@param value boolean
---@return boolean
function GameStateRuntime:set_turbo(value)
    local global = self._df.global
    assert(global and type(global.debug_turbospeed) == 'boolean',
        'DwarfSpec could not set native turbo speed: ' ..
            'df.global.debug_turbospeed is unavailable')
    global.debug_turbospeed = value
    return global.debug_turbospeed == value
end

---Returns a validated immutable-shaped game-speed observation.
---@return table
function GameStateRuntime:speed_state()
    local enabler = self._context.get_game_enabler()
    assert(enabler ~= nil,
        'DwarfSpec setGameSpeed requires df.global.enabler')
    assert(is_finite_number(enabler.fps) and enabler.fps >= 1 and
            enabler.fps % 1 == 0,
        'DwarfSpec setGameSpeed requires a valid positive integer ' ..
            'df.global.enabler.fps')
    assert(is_finite_number(enabler.gfps) and enabler.gfps > 0,
        'DwarfSpec setGameSpeed requires a valid positive ' ..
            'df.global.enabler.gfps')
    assert(is_finite_number(enabler.fps_per_gfps),
        'DwarfSpec setGameSpeed requires a valid ' ..
            'df.global.enabler.fps_per_gfps')
    return {tps=enabler.fps, graphical_rate=enabler.gfps,
        ratio=enabler.fps_per_gfps}
end

---Applies one game-speed observation.
---@param state table
---@return boolean
function GameStateRuntime:set_speed(state)
    local enabler = assert(self._context.get_game_enabler(),
        'DwarfSpec could not set game speed: df.global.enabler is unavailable')
    return self._context.set_game_speed(enabler, state.tps, state.ratio) ~=
        false
end

return GameStateRuntime
