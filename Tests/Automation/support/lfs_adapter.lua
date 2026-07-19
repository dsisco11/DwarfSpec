-- DFHack filesystem adapter for the LuaFileSystem surface used by Penlight.

local M = {}

---Returns LuaFileSystem-compatible attributes for an existing path.
---@param path string
---@param attribute? string
---@return table|any|nil
function M.attributes(path, attribute)
    local mode
    if dfhack.filesystem.isfile(path) then
        mode = 'file'
    elseif dfhack.filesystem.isdir(path) then
        mode = 'directory'
    else
        return nil
    end

    local size = 0
    if mode == 'file' then
        local file = io.open(path, 'rb')
        if file then
            size = file:seek('end') or 0
            file:close()
        end
    end
    local modification = dfhack.filesystem.mtime(path)
    local result = {
        mode=mode,
        size=size,
        modification=modification,
        access=modification,
        change=modification,
    }
    if attribute then return result[attribute] end
    return result
end

---Returns attributes without following links; DFHack exposes no link split.
---@param path string
---@param attribute? string
---@return table|any|nil
function M.symlinkattributes(path, attribute)
    return M.attributes(path, attribute)
end

---Returns the current process working directory.
---@return string
function M.currentdir()
    return dfhack.filesystem.getcwd()
end

---Rejects process-wide working-directory changes in live automation.
---@param path string
function M.chdir(path)
    error(('chdir(%s) is forbidden in live automation')
        :format(tostring(path)), 2)
end

---Creates one directory.
---@param path string
---@return boolean
function M.mkdir(path)
    return dfhack.filesystem.mkdir(path)
end

---Removes one empty directory.
---@param path string
---@return boolean
function M.rmdir(path)
    return dfhack.filesystem.rmdir(path)
end

---Iterates LuaFileSystem-style names within a directory.
---@param path string
---@return fun(): string|nil
function M.dir(path)
    local entries = {'.', '..'}
    for _, entry in ipairs(dfhack.filesystem.listdir(path)) do
        table.insert(entries, entry)
    end
    local index = 0
    return function()
        index = index + 1
        return entries[index]
    end
end

return M
