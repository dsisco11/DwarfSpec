-- TestBed-private module and script source resolution.

local M = {}

---Returns the platform's package-path template separator.
---@return string
local function path_separator()
    return package.config:sub(3, 3)
end

---Returns whether one path is absolute on Windows or Unix-like platforms.
---@param path string
---@return boolean
local function is_absolute(path)
    return path:match('^[/\\]') ~= nil or path:match('^[A-Za-z]:[/\\]') ~= nil
end

---Returns the current process directory without depending on a project layout.
---@return string
local function current_directory()
    local command = package.config:sub(1, 1) == '\\' and 'cd' or 'pwd'
    local process = assert(io.popen(command, 'r'),
        'TestBed could not determine the process current directory')
    local directory = process:read('*l')
    process:close()
    return assert(directory and directory ~= '',
        'TestBed could not determine the process current directory')
end

---Normalizes separators and lexical dot segments without enforcing containment.
---@param path string
---@return string
local function normalize(path)
    local value = path:gsub('\\', '/'):gsub('/+', '/')
    local prefix = ''
    local remainder = value
    local drive = value:match('^([A-Za-z]:)/')
    if drive then
        prefix = drive:upper() .. '/'
        remainder = value:sub(4)
    elseif value:sub(1, 1) == '/' then
        prefix = '/'
        remainder = value:sub(2)
    end
    local segments = {}
    for segment in remainder:gmatch('[^/]+') do
        if segment == '..' then
            if #segments > 0 and segments[#segments] ~= '..' then
                table.remove(segments)
            elseif prefix == '' then
                table.insert(segments, segment)
            end
        elseif segment ~= '.' and segment ~= '' then
            table.insert(segments, segment)
        end
    end
    local result = prefix .. table.concat(segments, '/')
    if result == '' then return prefix ~= '' and prefix or '.' end
    return result
end

---Resolves one path against a root while preserving ordinary parent traversal.
---@param root string
---@param path string
---@return string
local function resolve(root, path)
    if is_absolute(path) then return normalize(path) end
    return normalize(root .. '/' .. path)
end

---Returns whether a resolved filename is readable.
---@param filename string
---@return boolean
local function file_exists(filename)
    local file = io.open(filename, 'rb')
    if not file then return false end
    file:close()
    return true
end

---Escapes a string for use as a literal Lua pattern fragment.
---@param value string
---@return string
local function escape_pattern(value)
    return (value:gsub('([^%w])', '%%%1'))
end

---Searches an explicit Lua path using native-compatible template semantics.
---@param name string
---@param path string
---@param exists fun(filename: string): boolean
---@param separator? string
---@param replacement? string
---@return string|nil, string|nil
local function searchpath(name, path, exists, separator, replacement)
    separator = separator or '.'
    replacement = replacement or '/'
    local transformed = name:gsub(escape_pattern(separator), replacement)
    local errors = {}
    for template in path:gmatch('[^' .. path_separator() .. ']+') do
        local candidate = template:gsub('%?', transformed)
        if exists(candidate) then return candidate end
        table.insert(errors, "\n\tno file '" .. candidate .. "'")
    end
    if #errors == 0 then
        table.insert(errors, '\n\tno file (private package.path is empty)')
    end
    return nil, table.concat(errors)
end

---Owns deterministic source resolution for one normalized TestBed configuration.
---@class dwarfspec.testbed.Paths
---@field consumer_root string
---@field module_roots string[]
---@field script_roots string[]
---@field package_path string
---@field file_exists fun(filename: string): boolean
local Paths = {}
Paths.__index = Paths

---Constructs path state from a normalized configuration snapshot.
---@param normalized table
---@param options? table
---@return dwarfspec.testbed.Paths
function Paths.new(normalized, options)
    assert(type(normalized) == 'table', 'TestBed paths require normalized configuration')
    options = options or {}
    assert(type(options) == 'table', 'TestBed path options must be a table')
    local get_current_directory = options.current_directory or current_directory
    local exists = options.file_exists or file_exists
    assert(type(get_current_directory) == 'function',
        'TestBed path current_directory must be a function')
    assert(type(exists) == 'function', 'TestBed path file_exists must be a function')
    local root = normalized.consumer_root
    assert(type(root) == 'string', 'TestBed normalized consumer root must be a string')
    if not is_absolute(root) then root = resolve(get_current_directory(), root) end
    local module_roots, script_roots = {}, {}
    for index, configured_root in ipairs(normalized.module_roots) do
        module_roots[index] = resolve(root, configured_root)
    end
    for index, configured_root in ipairs(normalized.script_roots) do
        script_roots[index] = resolve(root, configured_root)
    end
    local templates = {}
    for _, module_root in ipairs(module_roots) do
        table.insert(templates, module_root .. '/?.lua')
        table.insert(templates, module_root .. '/?/init.lua')
    end
    return setmetatable({consumer_root=root, module_roots=module_roots,
        script_roots=script_roots, package_path=table.concat(templates,
            path_separator()), file_exists=exists}, Paths)
end

---Searches the supplied private package path for one ordinary Lua module.
---@param name string
---@param path? string
---@return string|nil, string|nil
function Paths:find_module(name, path)
    assert(type(name) == 'string', 'TestBed module name must be a string')
    path = path or self.package_path
    assert(type(path) == 'string', 'TestBed private package.path must be a string')
    local filename, message = searchpath(name, path, self.file_exists)
    if filename then return filename end
    return nil, ('TestBed module %q was not found from consumer root %q using roots [%s]:%s'):
        format(name, self.consumer_root, table.concat(self.module_roots, ', '),
            message)
end

---Resolves one logical DFHack-style script name through the declared roots.
---@param name string
---@return string|nil, string|nil
function Paths:find_script(name)
    assert(type(name) == 'string', 'TestBed script name must be a string')
    local candidates = {}
    local logical_filename = name:gsub('\\', '/') .. '.lua'
    for _, script_root in ipairs(self.script_roots) do
        local candidate = resolve(script_root, logical_filename)
        if self.file_exists(candidate) then return candidate end
        table.insert(candidates, candidate)
    end
    return nil, ('TestBed script %q was not found under roots [%s]; tried [%s]'):
        format(name, table.concat(self.script_roots, ', '), table.concat(candidates, ', '))
end

---Resolves an exact provider source path against this bed's consumer root.
---@param path string
---@return string
function Paths:resolve_source(path)
    assert(type(path) == 'string', 'TestBed provider source path must be a string')
    return resolve(self.consumer_root, path)
end

---Searches one supplied path with the private native-compatible algorithm.
---@param name string
---@param path string
---@param separator? string
---@param replacement? string
---@return string|nil, string|nil
function Paths:searchpath(name, path, separator, replacement)
    assert(type(name) == 'string', 'TestBed searchpath name must be a string')
    assert(type(path) == 'string', 'TestBed searchpath path must be a string')
    return searchpath(name, path, self.file_exists, separator, replacement)
end

M.Paths = Paths

return M
