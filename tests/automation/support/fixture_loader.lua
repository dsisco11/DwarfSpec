-- Explicit consumer fixture importer for live automation screens.

local M = {}

---Resolves and validates one project-relative fixture module path.
---@param project table
---@param import_path string
---@return string, string
function M.resolve(project, import_path)
    assert(type(project) == 'table' and type(project.project_root) == 'string',
        'fixture loading requires a project descriptor')
local ok, project_module = pcall(require, 'dwarfspec.automation.project')
if not ok then
    project_module = assert(loadfile(project.package_root ..
        '/tests/automation/support/project.lua'))()
end
    local relative_path = project_module.relative_path(import_path)
    assert(relative_path:match('%.lua$'),
        'fixture import must name one Lua module: ' .. relative_path)
    local absolute_path = project_module.join(project.project_root,
        relative_path)
    assert(project.filesystem.isfile(absolute_path),
        'fixture module was not found: ' .. relative_path)
    return absolute_path, relative_path
end

---Explicitly imports one fixture module from the consumer project.
---@param project table
---@param import_path string
---@param loader function|nil
---@return table
function M.load(project, import_path, loader)
    local absolute_path, relative_path = M.resolve(project, import_path)
    local chunk, load_error = (loader or loadfile)(absolute_path)
    assert(chunk, relative_path .. ': could not load fixture: ' ..
        tostring(load_error))
    local ok, fixture = xpcall(chunk, debug.traceback)
    assert(ok, relative_path .. ': fixture failed to load: ' ..
        tostring(fixture))
    assert(type(fixture) == 'table' and type(fixture.new) == 'function',
        'automation fixture must export new(options): ' .. relative_path)
    return fixture
end

return M
