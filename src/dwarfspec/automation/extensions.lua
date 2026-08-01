-- Production consumer configuration, command, and diagnostic extension loader.

local config_schema = require('dwarfspec.protocol.configuration.schema')
local M = {}
local settings_validator = require('dwarfspec.protocol.configuration.settings')

---Registers one validated command map without permitting duplicates.
---@param target table
---@param callbacks any
---@param source string
local function register_commands(target, callbacks, source)
    callbacks = config_schema.validate_commands(callbacks, source)
    for name, callback in pairs(callbacks) do
        local previous = target[name]
        assert(not previous, ('%s: duplicate commands %q; first registered by %s')
            :format(source, name,
                previous and previous.source or '<unknown>'))
        target[name] = {callback=callback, source=source}
    end
end

---Loads one consumer module in an environment isolated from process globals.
---@param absolute_path string
---@param relative_path string
---@param loader function
---@return table
local function load_module(absolute_path, relative_path, loader)
    local environment = setmetatable({}, {__index=_G})
    local chunk, load_error = loader(absolute_path, 't', environment)
    assert(chunk, relative_path .. ': could not load module: ' ..
        tostring(load_error))
    local ok, result = xpcall(chunk, debug.traceback)
    assert(ok, relative_path .. ': module failed: ' .. tostring(result))
    assert(type(result) == 'table',
        relative_path .. ': module must return a table')
    for key in pairs(result) do
        assert(key == 'settings' or key == 'commands',
            relative_path .. ': unknown module field: ' .. tostring(key))
    end
    return result
end

---Loads deterministic project-wide settings and isolated ds extensions.
---@param project table
---@param loader function|nil
---@return table
function M.load(project, loader)
    assert(type(project) == 'table' and type(project.project_root) == 'string',
        'extension loading requires a project descriptor')
    loader = loader or loadfile
    local result = {
        settings=settings_validator.validate(
            nil, 'tests/dwarfspec/config.lua'),
        commands={},
        modules={},
    }
local ok, project_module = pcall(require, 'dwarfspec.automation.project')
if not ok then
    project_module = assert(loadfile(project.package_root ..
        '/src/dwarfspec/automation/project.lua'))()
end
    for _, relative_path in ipairs(
            project_module.discover_config_modules(project)) do
        local absolute_path = project_module.join(project.project_root,
            relative_path)
        local module = load_module(absolute_path, relative_path, loader)
        local module_commands = module.commands
        if relative_path:match('/config%.lua$') then
            local validated = config_schema.validate(module, relative_path)
            result.settings = validated.settings
            module_commands = validated.commands
        else
            assert(module.settings == nil,
                relative_path .. ': settings are only allowed in config.lua')
        end
        register_commands(result.commands, module_commands, relative_path)
        table.insert(result.modules, relative_path)
    end
    return result
end

return M
