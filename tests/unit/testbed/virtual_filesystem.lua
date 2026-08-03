-- In-memory source filesystem used by TestBed unit suites.

local M = {}

---Owns normalized virtual source paths and their Lua text.
---@class dwarfspec.testbed.spec.VirtualFilesystem
---@field root string
---@field sources table<string, string>
local VirtualFilesystem = {}
VirtualFilesystem.__index = VirtualFilesystem

---Normalizes a virtual path to the separators used by TestBed resolution.
---@param path string
---@return string
local function normalize(path)
    return path:gsub('\\', '/'):gsub('/+', '/')
end

---Constructs an empty filesystem rooted at an absolute consumer path.
---@param root? string
---@return dwarfspec.testbed.spec.VirtualFilesystem
function VirtualFilesystem.new(root)
    root = normalize(root or '/virtual-consumer')
    assert(root:sub(1, 1) == '/' or root:match('^[A-Za-z]:/'),
        'Virtual TestBed filesystem root must be absolute')
    return setmetatable({root=root, sources={}}, VirtualFilesystem)
end

---Resolves one relative fixture path beneath the virtual consumer root.
---@param path string
---@return string
function VirtualFilesystem:resolve(path)
    path = normalize(path)
    if path:sub(1, 1) == '/' or path:match('^[A-Za-z]:/') then return path end
    if path == '.' then return self.root end
    path = path:gsub('^%./', '')
    return normalize(self.root .. '/' .. path)
end

---Adds or replaces one virtual source file.
---@param path string
---@param source string
---@return string filename
function VirtualFilesystem:add(path, source)
    local filename = self:resolve(path)
    self.sources[filename] = source
    return filename
end

---Adds a consumer fixture map keyed by paths relative to the virtual root.
---@param sources table<string, string>
function VirtualFilesystem:add_all(sources)
    for path, source in pairs(sources) do self:add(path, source) end
end

---Returns whether an exact virtual filename exists.
---@param filename string
---@return boolean
function VirtualFilesystem:file_exists(filename)
    return self.sources[normalize(filename)] ~= nil
end

---Returns whether a virtual directory contains at least one source file.
---@param directory string
---@return boolean
function VirtualFilesystem:directory_exists(directory)
    local prefix = self:resolve(directory)
    if prefix:sub(-1) ~= '/' then prefix = prefix .. '/' end
    for filename in pairs(self.sources) do
        if filename:sub(1, #prefix) == prefix then return true end
    end
    return false
end

---Reads an exact virtual source file or raises the production-shaped error.
---@param filename string
---@return string
function VirtualFilesystem:read_source(filename)
    local source = self.sources[normalize(filename)]
    assert(source ~= nil, 'TestBed could not read virtual source ' .. filename)
    return source
end

---Compiles an exact virtual source file into the supplied environment.
---@param filename string
---@param mode? string
---@param environment? table
---@return function|nil, string|nil
function VirtualFilesystem:loadfile(filename, mode, environment)
    local source = self.sources[normalize(filename)]
    if source == nil then return nil, 'cannot open ' .. filename .. ': virtual file not found' end
    return load(source, '@' .. normalize(filename), mode, environment)
end

---Builds private construction options backed by this filesystem.
---@param additional? table
---@return table
function VirtualFilesystem:options(additional)
    local options = {}
    for key, value in pairs(additional or {}) do options[key] = value end
    options.consumer_root = options.consumer_root or self.root
    options.directory_exists = function(directory) return self:directory_exists(directory) end
    options.current_directory = function() return '/' end
    options.file_exists = function(filename) return self:file_exists(filename) end
    options.read_source = function(filename) return self:read_source(filename) end
    options.loadfile = function(filename, mode, environment)
        return self:loadfile(filename, mode, environment)
    end
    options.load_chunk = function(filename, environment)
        return self:loadfile(filename, nil, environment)
    end
    return options
end

M.VirtualFilesystem = VirtualFilesystem

return M
