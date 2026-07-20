-- Resolves consumer-project test assets without product-specific assumptions.

local M = {}

---Joins portable path segments with the active platform separator.
---@param root string
---@param relative_path string
---@return string
function M.join(root, relative_path)
    local separator = package.config:sub(1, 1)
    return root .. separator .. relative_path:gsub('[/\\]', separator)
end

---Validates a project-relative path that cannot escape its declared root.
---@param relative_path string
---@return string
function M.relative_path(relative_path)
    assert(type(relative_path) == 'string' and relative_path ~= '',
        'project-relative path must be a nonempty string')
    assert(not relative_path:match('^[/\\]') and
        not relative_path:match('^[A-Za-z]:[/\\]') and
        relative_path ~= '..' and
        not relative_path:match('^%.%.[/\\]') and
        not relative_path:match('[/\\]%.%.[/\\]') and
        not relative_path:match('[/\\]%.%.$'),
        'project-relative path must not escape its root: ' .. relative_path)
    return relative_path:gsub('\\', '/')
end

---Builds a consumer project descriptor from explicit paths and filesystem APIs.
---@param project_root string
---@param package_root string
---@param filesystem table
---@return table
function M.new(project_root, package_root, filesystem)
    assert(type(project_root) == 'string' and project_root ~= '',
        'project root must be a nonempty string')
    assert(type(package_root) == 'string' and package_root ~= '',
        'DwarfSpec package root must be a nonempty string')
    assert(type(filesystem) == 'table' and
        type(filesystem.isfile) == 'function' and
        type(filesystem.isdir) == 'function' and
        type(filesystem.listdir) == 'function',
        'project filesystem must provide isfile, isdir, and listdir')
    assert(filesystem.isdir(project_root),
        'project root is not a directory: ' .. project_root)
    return {
        project_root=project_root,
        package_root=package_root,
        filesystem=filesystem,
        tests_root=M.join(project_root, 'tests'),
    }
end

---Returns sorted project-relative live spec paths beneath the tests directory.
---@param project table
---@return string[]
function M.discover_specs(project)
    assert(project.filesystem.isdir(project.tests_root),
        'project tests directory was not found: ' .. project.tests_root)
    local specs = {}
    local function visit(directory, relative_directory)
        local entries = project.filesystem.listdir(directory)
        table.sort(entries)
        for _, entry in ipairs(entries) do
            local relative = relative_directory == '' and entry or
                relative_directory .. '/' .. entry
            local path = M.join(directory, entry)
            if project.filesystem.isdir(path) then
                visit(path, relative)
            elseif project.filesystem.isfile(path) and
                    entry:match('_spec%.ds%.lua$') then
                table.insert(specs, relative)
            end
        end
    end
    visit(project.tests_root, '')
    return specs
end

---Returns sorted optional global configuration module paths.
---@param project table
---@return string[]
function M.discover_config_modules(project)
    local directory = M.join(project.tests_root, 'dwarfspec')
    if not project.filesystem.isdir(directory) then return {} end
    local modules = {}
    for _, entry in ipairs(project.filesystem.listdir(directory)) do
        if entry:match('%.lua$') and project.filesystem.isfile(
                M.join(directory, entry)) then
            table.insert(modules, 'tests/dwarfspec/' .. entry)
        end
    end
    table.sort(modules)
    return modules
end

return M
