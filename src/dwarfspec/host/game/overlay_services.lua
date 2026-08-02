-- Host-owned external services for overlay registration staging.

local M = {}

---Reads one complete binary file or raises its operating-system error.
---@param path string
---@return string
local function read_file(path)
    local file, open_error = io.open(path, 'rb')
    assert(file, open_error)
    local contents = file:read('*a')
    file:close()
    return contents
end

---Writes one complete binary file or raises its operating-system error.
---@param path string
---@param contents string
local function write_file(path, contents)
    local file, open_error = io.open(path, 'wb')
    assert(file, open_error)
    local written, write_error = file:write(contents)
    file:close()
    assert(written, write_error)
end

---Creates native DFHack services for registration and configuration cleanup.
---@return table
function M.new()
    local overlay = require('plugins.overlay')
    return {
        destination_directory=dfhack.getDFPath() .. '/hack/scripts/gui',
        config_path=dfhack.getDFPath() .. '/dfhack-config/overlay.json',
        isfile=dfhack.filesystem.isfile,
        read_file=read_file,
        write_file=write_file,
        remove_file=os.remove,
        rescan=function() overlay.rescan() end,
        registered_names=function(script_name)
            local prefix = 'gui/' .. script_name .. '.'
            local names = {}
            for name in pairs(overlay.get_state().db) do
                if name:sub(1, #prefix) == prefix then
                    table.insert(names, name)
                end
            end
            table.sort(names)
            return names
        end,
        is_enabled=function(name)
            return not not overlay.isOverlayEnabled(name)
        end,
        disable=function(name)
            overlay.overlay_command({'disable', name}, true)
            assert(not overlay.isOverlayEnabled(name),
                'overlay remained enabled after disable: ' .. name)
        end,
    }
end

return M
