-- Cohesive run-scoped save-game host and transition access.

---@class dwarfspec.SaveGameRuntime
---@field private _host table
---@field private _loader table
---@field private _unloader table
local SaveGameRuntime = {}
SaveGameRuntime.__index = SaveGameRuntime

---Creates save-game runtime support around one run's host adapters.
---@param options table
---@return dwarfspec.SaveGameRuntime
function SaveGameRuntime.new(options)
    assert(type(options) == 'table', 'save-game runtime options are required')
    for _, name in ipairs({'host', 'loader', 'unloader'}) do
        assert(type(options[name]) == 'table',
            'save-game runtime requires ' .. name)
    end
    assert(type(options.host.is_world_loaded) == 'function' and
            type(options.host.read_world_folder) == 'function',
        'save-game runtime requires host inspection')
    for _, name in ipairs({'reach_save_menu', 'select_save_world',
            'select_save_and_await_map', 'verify_loaded'}) do
        assert(type(options.loader[name]) == 'function',
            'save-game runtime loader requires ' .. name)
    end
    assert(type(options.unloader.unload) == 'function',
        'save-game runtime unloader requires unload')
    return setmetatable({_host=options.host, _loader=options.loader,
        _unloader=options.unloader}, SaveGameRuntime)
end

---Returns the host inspection contract used by stateless workflow validation.
---@return table
function SaveGameRuntime:host()
    return self._host
end

---Returns whether a world is currently loaded.
---@return boolean
function SaveGameRuntime:is_world_loaded()
    return self._host.is_world_loaded()
end

---Unloads the current save before a requested transition.
---@param current string
---@param requested string
function SaveGameRuntime:unload(current, requested)
    return self._unloader:unload(current, requested)
end

---Reaches the save menu for one requested directory.
---@param directory string
---@return table
function SaveGameRuntime:reach_save_menu(directory)
    return self._loader:reach_save_menu(directory)
end

---Selects the requested world from the save menu.
---@param directory string
---@param world_id any
---@return table
function SaveGameRuntime:select_save_world(directory, world_id)
    return self._loader:select_save_world(directory, world_id)
end

---Selects an exact save and awaits its map transition.
---@param directory string
---@param save_index any
function SaveGameRuntime:select_save_and_await_map(directory, save_index)
    return self._loader:select_save_and_await_map(directory, save_index)
end

---Verifies that the exact requested directory is loaded.
---@param directory string
---@return string
function SaveGameRuntime:verify_loaded(directory)
    return self._loader:verify_loaded(directory)
end

return SaveGameRuntime
