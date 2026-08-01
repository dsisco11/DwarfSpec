-- Static dependency-direction contracts for driver production modules.

local lfs = require('lfs')

local DRIVER_ROOT = 'src/dwarfspec/driver'

---Returns every Lua source beneath one directory in stable path order.
---@param root string
---@return string[]
local function lua_sources(root)
    local sources = {}

    ---Collects Lua sources recursively without loading them.
    ---@param directory string
    local function collect(directory)
        for name in lfs.dir(directory) do
            if name ~= '.' and name ~= '..' then
                local path = directory .. '/' .. name
                local mode = assert(lfs.attributes(path, 'mode'))
                if mode == 'directory' then
                    collect(path)
                elseif mode == 'file' and name:match('%.lua$') then
                    table.insert(sources, path)
                end
            end
        end
    end

    collect(root)
    table.sort(sources)
    return sources
end

---Reads one complete Lua source file.
---@param path string
---@return string
local function read_source(path)
    local file = assert(io.open(path, 'rb'))
    local contents = assert(file:read('*a'))
    file:close()
    return contents
end

---Returns literal module names from static require declarations.
---@param contents string
---@return string[]
local function declared_imports(contents)
    local imports = {}
    for name in contents:gmatch("require%s*%(%s*'([^']+)'%s*%)") do
        table.insert(imports, name)
    end
    for name in contents:gmatch('require%s*%(%s*"([^"]+)"%s*%)') do
        table.insert(imports, name)
    end
    for name in contents:gmatch("require%s*'([^']+)'") do
        table.insert(imports, name)
    end
    for name in contents:gmatch('require%s*"([^"]+)"') do
        table.insert(imports, name)
    end
    return imports
end

describe('driver dependency rules', function()
    it('rejects declared static imports of host modules', function()
        local violations = {}
        for _, path in ipairs(lua_sources(DRIVER_ROOT)) do
            for _, module_name in ipairs(
                    declared_imports(read_source(path))) do
                if module_name:match('^dwarfspec%.host[%.]') then
                    table.insert(violations,
                        path .. ': ' .. module_name)
                end
            end
        end

        assert.same({}, violations)
    end)
end)
