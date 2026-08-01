-- Dynamic live save selection for save-game command acceptance tests.

local M = {}

---Returns one path's parent directory.
---@param path string
---@return string
local function parent_path(path)
    return assert(path:match('^(.*)[/\\][^/\\]+$'),
        'save-game fixture path has no parent: ' .. path)
end

---Returns the native save root in loaded and unloaded states.
---@return string
local function save_root()
    if dfhack.isWorldLoaded() then
        local loaded_path = tostring(df.global.world.loaded_save_path)
        assert(loaded_path ~= '',
            'save-game fixtures require a loaded native save path')
        return parent_path(loaded_path)
    end

    local screen = dfhack.gui.getCurViewscreen(true)
    assert(df.viewscreen_titlest:is_instance(screen),
        'save-game fixtures require the native title screen when unloaded')
    local header = screen.savegame_header[0]
    assert(header,
        'save-game fixtures require at least one native save header')
    return parent_path(tostring(header.full_path))
end

---Returns the byte size of one save directory's world.sav file.
---@param path string
---@return integer
local function world_save_size(path)
    local world_save_path = path .. '/world.sav'
    local file = assert(io.open(world_save_path, 'rb'),
        'could not open save file for sizing: ' .. world_save_path)
    local size = assert(file:seek('end'),
        'could not size save file: ' .. world_save_path)
    file:close()
    return size
end

---Returns the currently loaded save-directory name.
---@return string
function M.current_directory()
    assert(dfhack.isWorldLoaded(),
        'save-game fixtures require a loaded world')
    local directory = dfhack.world.ReadWorldFolder()
    assert(type(directory) == 'string' and directory ~= '',
        'save-game fixtures require a valid loaded save directory')
    return directory
end

---Returns the smallest selectable save, optionally excluding one directory.
---Size is world.sav bytes with directory name as a tie-breaker.
---@param excluded_directory string|nil
---@return string, integer
function M.smallest_directory(excluded_directory)
    assert(excluded_directory == nil or
            (type(excluded_directory) == 'string' and
                excluded_directory ~= ''),
        'smallest save selection requires a valid excluded directory name')
    local root = save_root()
    local entries = assert(dfhack.filesystem.listdir_recursive(root, 0, false),
        'save-game fixtures could not enumerate the native save root')
    local selected
    for _, entry in ipairs(entries) do
        local directory = entry.path
        if entry.isdir and directory ~= excluded_directory then
            local path = root .. '/' .. directory
            local world_save = io.open(path .. '/world.sav', 'rb')
            if world_save then
                world_save:close()
                local size = world_save_size(path)
                if not selected or size < selected.size or
                        (size == selected.size and
                            directory < selected.directory) then
                    selected = {
                        directory=directory,
                        size=size,
                    }
                end
            end
        end
    end
    assert(selected,
        'save-game fixtures found no alternate selectable save directory')
    return selected.directory, selected.size
end

---Returns the smallest selectable save other than the supplied directory.
---@param excluded_directory string
---@return string, integer
function M.smallest_alternate_directory(excluded_directory)
    assert(type(excluded_directory) == 'string' and
            excluded_directory ~= '',
        'smallest alternate save selection requires an excluded directory')
    return M.smallest_directory(excluded_directory)
end

return M
