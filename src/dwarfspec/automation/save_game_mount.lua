-- Preflight validation for save-game mounting without changing game state.

local M = {}

---Validates the sole public save-directory argument.
---@param argument_count integer
---@param directory_name any
---@return string
function M.validate_directory_name(argument_count, directory_name)
    assert(argument_count == 1,
        'DwarfSpec mountSaveGame requires exactly one save directory name')
    assert(type(directory_name) == 'string' and directory_name ~= '',
        'DwarfSpec mountSaveGame requires a nonempty save directory name')
    assert(directory_name ~= '.' and directory_name ~= '..' and
            not directory_name:find('[\\/]', 1) and
            not directory_name:match('^[A-Za-z]:') and
            not directory_name:find('\0', 1, true),
        'DwarfSpec mountSaveGame requires one directory name, not a path')
    return directory_name
end

---Reads and validates the currently loaded save-directory name.
---@param read_world_folder function
---@return string
local function read_loaded_directory(read_world_folder)
    assert(type(read_world_folder) == 'function',
        'DwarfSpec mountSaveGame requires dfhack.world.ReadWorldFolder')
    local directory_name = read_world_folder()
    assert(type(directory_name) == 'string' and directory_name ~= '',
        'DFHack ReadWorldFolder did not return a valid save directory name')
    return directory_name
end

---Determines whether mounting one requested save requires a world transition.
---@param dependencies table
---@param argument_count integer
---@param directory_name any
---@return table
function M.preflight(dependencies, argument_count, directory_name)
    assert(type(dependencies) == 'table',
        'save-game mount dependencies must be a table')
    local requested_directory = M.validate_directory_name(argument_count,
        directory_name)
    local is_world_loaded = dependencies.is_world_loaded
    assert(type(is_world_loaded) == 'function',
        'DwarfSpec mountSaveGame requires dfhack.isWorldLoaded')

    if not is_world_loaded() then
        return {
            requested_directory=requested_directory,
            loaded_directory=nil,
            transition_required=true,
        }
    end

    local loaded_directory = read_loaded_directory(
        dependencies.read_world_folder)
    return {
        requested_directory=requested_directory,
        loaded_directory=loaded_directory,
        transition_required=loaded_directory ~= requested_directory,
    }
end

return M
