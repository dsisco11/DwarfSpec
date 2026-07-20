-- DFHack core-context adapter for the LuaSystem surface used by Busted.

local M = {
    _VERSION='DFHack automation adapter 1',
    windows=true,
}
local random_generator = dfhack.random.new()

---Returns wall-clock-like seconds for Busted duration reporting.
---@return number
function M.gettime()
    return dfhack.getTickCount() / 1000
end

---Returns monotonic seconds for Busted duration reporting.
---@return number
function M.monotime()
    return dfhack.getTickCount() / 1000
end

---Rejects blocking sleeps in DFHack's core context.
---@param seconds number
function M.sleep(seconds)
    error(('blocking sleep(%s) is forbidden in live automation; yield through ds')
        :format(tostring(seconds)), 2)
end

---Returns one process environment variable.
---@param name string
---@return string|nil
function M.getenv(name)
    return os.getenv(name)
end

---Returns the environment surface required by the current Busted host.
---@return table
function M.getenvs()
    return {}
end

---Rejects process-wide environment mutation from live automation.
---@param name string
---@param value string|nil
function M.setenv(name, value)
    error(('setenv(%s, %s) is forbidden in live automation')
        :format(tostring(name), tostring(value)), 2)
end

---Reports that redirected DFHack automation output is not a terminal.
---@return boolean
function M.isatty()
    return false
end

---Returns pseudo-random bytes for non-cryptographic test seeds.
---@param length integer
---@return string
function M.random(length)
    local bytes = {}
    for index = 1, length do
        bytes[index] = string.char(random_generator:random(256))
    end
    return table.concat(bytes)
end

return M
