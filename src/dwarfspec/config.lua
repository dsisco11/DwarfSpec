-- External consumer configuration needed before live test discovery.

local glob = require('dwarfspec.glob')
local project = require('dwarfspec.project')

local M = {
    default_test_glob=project.default_test_glob,
}

---Loads the project test-file glob without executing any test file or hook.
---@param project_root string
---@param filesystem table
---@param loader function|nil
---@return string
function M.load_test_glob(project_root, filesystem, loader)
    local relative_path = 'tests/dwarfspec/config.lua'
    local absolute_path = project.join(project_root, relative_path)
    if not filesystem.isfile(absolute_path) then
        return M.default_test_glob
    end

    loader = loader or loadfile
    local environment = setmetatable({}, {__index=_G})
    local chunk, load_error = loader(absolute_path, 't', environment)
    assert(chunk, relative_path .. ': could not load module: ' ..
        tostring(load_error))
    local ok, result = xpcall(chunk, debug.traceback)
    assert(ok, relative_path .. ': module failed: ' .. tostring(result))
    assert(type(result) == 'table', relative_path ..
        ': module must return a table')

    local settings = result.settings or {}
    assert(type(settings) == 'table', relative_path ..
        ': settings must be a table')
    local discovery = settings.discovery or {}
    assert(type(discovery) == 'table', relative_path ..
        ': settings.discovery must be a table')
    for key in pairs(discovery) do
        assert(key == 'test_glob', relative_path ..
            ': unknown discovery setting: ' .. tostring(key))
    end
    local test_glob = discovery.test_glob or M.default_test_glob
    assert(type(test_glob) == 'string' and test_glob ~= '', relative_path ..
        ': settings.discovery.test_glob must be a nonempty string')
    glob.compile(test_glob)
    return test_glob
end

return M
