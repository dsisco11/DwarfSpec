-- External consumer configuration needed before live test discovery.

local ErrorFormat = require('dwarfspec.protocol.configuration.error_formats')
local config_schema = require('dwarfspec.protocol.configuration.schema')
local project = require('dwarfspec.project')
local settings_validator = require('dwarfspec.protocol.configuration.settings')

local M = {
    default_test_glob=project.default_test_glob,
    default_error_format=ErrorFormat.MSBUILD,
}

---Loads validated external settings without executing test files or hooks.
---@param project_root string
---@param filesystem table
---@param loader function|nil
---@return table
function M.load(project_root, filesystem, loader)
    local relative_path = 'tests/dwarfspec/config.lua'
    local absolute_path = project.join(project_root, relative_path)
    if not filesystem.isfile(absolute_path) then
        local settings = settings_validator.validate(nil, relative_path)
        settings.discovery.test_glob = M.default_test_glob
        return {settings=settings}
    end

    loader = loader or loadfile
    local environment = setmetatable({}, {__index=_G})
    local chunk, load_error = loader(absolute_path, 't', environment)
    assert(chunk, relative_path .. ': could not load module: ' ..
        tostring(load_error))
    local ok, result = xpcall(chunk, debug.traceback)
    assert(ok, relative_path .. ': module failed: ' .. tostring(result))
    local validated = config_schema.validate(result, relative_path)
    local settings = validated.settings
    settings.discovery.test_glob =
        settings.discovery.test_glob or M.default_test_glob
    return {
        settings=settings,
    }
end

---Loads only the project test-file glob for compatibility callers.
---@param project_root string
---@param filesystem table
---@param loader function|nil
---@return string
function M.load_test_glob(project_root, filesystem, loader)
    return M.load(project_root, filesystem, loader)
        .settings.discovery.test_glob
end

return M
