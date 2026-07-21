-- Safe project-local dotenv parsing and environment overlays.

local M = {}

---Removes surrounding whitespace from one value.
---@param value string
---@return string
local function trim(value)
    return value:match('^%s*(.-)%s*$')
end

---Parses one dotenv value without executing or expanding it.
---@param raw string
---@param source string
---@param line_number integer
---@return string
local function parse_value(raw, source, line_number)
    raw = trim(raw)
    local quote = raw:sub(1, 1)
    if quote == '"' or quote == "'" then
        assert(#raw >= 2 and raw:sub(-1) == quote,
            ('unterminated quoted value at %s:%d'):format(source,
                line_number))
        return raw:sub(2, -2)
    end
    return trim((raw:gsub('%s+#.*$', '')))
end

---Parses dotenv assignments into an isolated key-value table.
---@param contents string
---@param source string|nil
---@return table
function M.parse(contents, source)
    assert(type(contents) == 'string', 'dotenv contents must be a string')
    source = source or '.env'
    local values = {}
    local line_number = 0
    for line in (contents .. '\n'):gmatch('(.-)\n') do
        line_number = line_number + 1
        line = line:gsub('\r$', '')
        local stripped = trim(line)
        if stripped ~= '' and stripped:sub(1, 1) ~= '#' then
            local name, raw = stripped:match(
                '^export%s+([A-Za-z_][A-Za-z0-9_]*)%s*=%s*(.*)$')
            if not name then
                name, raw = stripped:match(
                    '^([A-Za-z_][A-Za-z0-9_]*)%s*=%s*(.*)$')
            end
            assert(name,
                ('malformed dotenv assignment at %s:%d'):format(source,
                    line_number))
            assert(values[name] == nil,
                ('duplicate dotenv assignment for %s at %s:%d'):format(
                    name, source, line_number))
            values[name] = parse_value(raw, source, line_number)
        end
    end
    return values
end

---Reads and parses an optional dotenv file through supplied I/O seams.
---@param path string
---@param filesystem table
---@param readfile function|nil
---@return table
function M.load(path, filesystem, readfile)
    if not filesystem.isfile(path) then return {} end
    readfile = readfile or function(filename)
        local file = assert(io.open(filename, 'rb'))
        local contents = assert(file:read('*a'))
        file:close()
        return contents
    end
    return M.parse(assert(readfile(path)), path)
end

---Creates an environment provider with process values over dotenv defaults.
---@param environment table
---@param values table
---@return table
function M.overlay(environment, values)
    assert(type(environment) == 'table' and
        type(environment.getenv) == 'function',
        'base environment must provide getenv')
    return {
        getenv=function(name)
            local value = environment.getenv(name)
            if value ~= nil and value ~= '' then return value end
            return values[name]
        end,
    }
end

return M
