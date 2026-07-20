-- Approved test-fixture loader for live automation screens.

local M = {}

local APPROVED_FIXTURES = {
    cover_screen=true,
    interaction_screen=true,
    tooltip_screen=true,
}

---Joins a repository path with a portable relative path.
---@param root string
---@param relative_path string
---@return string
local function join_path(root, relative_path)
    local separator = package.config:sub(1, 1)
    return root .. separator .. relative_path:gsub('[/\\]', separator)
end

---Loads one named fixture from the approved fixture directory.
---@param repo_root string
---@param name string
---@return table
function M.load(repo_root, name)
    assert(type(name) == 'string' and name:match('^[%a_][%w_]*$'),
        'fixture name must be a relative identifier')
    assert(APPROVED_FIXTURES[name], 'unknown automation fixture: ' .. name)
    local fixture_path = join_path(repo_root,
        'Tests/Automation/fixtures/' .. name .. '.lua')
    local fixture = assert(loadfile(fixture_path))()
    assert(type(fixture) == 'table' and type(fixture.new) == 'function',
        'automation fixture must export new(options): ' .. name)
    return fixture
end

---Returns whether a fixture name is approved for automation use.
---@param name string
---@return boolean
function M.is_approved(name)
    return APPROVED_FIXTURES[name] == true
end

return M
