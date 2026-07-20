-- Isolated consumer configuration, command, and diagnostic extension loader.

local M = {}

local RESERVED_COMMANDS = {
    capture_screen=true,
    capture_view_tree=true,
    clear_pointer=true,
    click=true,
    diagnostic=true,
    dismiss=true,
    get=true,
    inspect=true,
    move_pointer_to=true,
    press=true,
    protocol_version=true,
    reset=true,
    send_input=true,
    set_pointer=true,
    show_fixture=true,
    stage_overlay_fixture=true,
    type=true,
    wait_for_render=true,
    wait_frames=true,
    await=true,
}

---Validates one positive integer setting when it is present.
---@param value any
---@param label string
local function optional_positive_integer(value, label)
    if value == nil then return end
    assert(type(value) == 'number' and value >= 1 and value % 1 == 0,
        label .. ' must be a positive integer')
end

---Copies and validates the supported global wait settings.
---@param value any
---@param source string
---@return table
local function validate_settings(value, source)
    if value == nil then return {} end
    assert(type(value) == 'table', source .. ': settings must be a table')
    for key in pairs(value) do
        assert(key == 'wait' or key == 'discovery',
            source .. ': unknown setting: ' .. tostring(key))
    end
    local wait = value.wait or {}
    assert(type(wait) == 'table', source .. ': settings.wait must be a table')
    for key in pairs(wait) do
        assert(key == 'frame_budget' or key == 'timeout_ms',
            source .. ': unknown wait setting: ' .. tostring(key))
    end
    optional_positive_integer(wait.frame_budget,
        source .. ': settings.wait.frame_budget')
    optional_positive_integer(wait.timeout_ms,
        source .. ': settings.wait.timeout_ms')
    local discovery = value.discovery or {}
    assert(type(discovery) == 'table', source ..
        ': settings.discovery must be a table')
    for key in pairs(discovery) do
        assert(key == 'test_glob', source ..
            ': unknown discovery setting: ' .. tostring(key))
    end
    assert(discovery.test_glob == nil or
        type(discovery.test_glob) == 'string' and
        discovery.test_glob ~= '', source ..
        ': settings.discovery.test_glob must be a nonempty string')
    return {
        wait={
            frame_budget=wait.frame_budget,
            timeout_ms=wait.timeout_ms,
        },
        discovery={test_glob=discovery.test_glob},
    }
end

---Registers one validated callback map without permitting duplicates.
---@param target table
---@param callbacks any
---@param kind string
---@param source string
local function register_callbacks(target, callbacks, kind, source)
    if callbacks == nil then return end
    assert(type(callbacks) == 'table',
        source .. ': ' .. kind .. ' must be a table')
    for name, callback in pairs(callbacks) do
        assert(type(name) == 'string' and name:match('^[%a_][%w_]*$'),
            source .. ': invalid ' .. kind .. ' name: ' .. tostring(name))
        assert(type(callback) == 'function',
            source .. ': ' .. kind .. '.' .. name .. ' must be a function')
        if kind == 'commands' then
            assert(not RESERVED_COMMANDS[name],
                source .. ': custom command conflicts with ds.' .. name)
        end
        local previous = target[name]
        assert(not previous, ('%s: duplicate %s %q; first registered by %s')
            :format(source, kind, name,
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
        assert(key == 'settings' or key == 'commands' or key == 'diagnostics',
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
    local result = {settings={}, commands={}, diagnostics={}, modules={}}
local ok, project_module = pcall(require, 'dwarfspec.automation.project')
if not ok then
    project_module = assert(loadfile(project.package_root ..
        '/tests/automation/support/project.lua'))()
end
    for _, relative_path in ipairs(
            project_module.discover_config_modules(project)) do
        local absolute_path = project_module.join(project.project_root,
            relative_path)
        local module = load_module(absolute_path, relative_path, loader)
        if relative_path:match('/config%.lua$') then
            result.settings = validate_settings(module.settings, relative_path)
        else
            assert(module.settings == nil,
                relative_path .. ': settings are only allowed in config.lua')
        end
        register_callbacks(result.commands, module.commands, 'commands',
            relative_path)
        register_callbacks(result.diagnostics, module.diagnostics,
            'diagnostics', relative_path)
        table.insert(result.modules, relative_path)
    end
    return result
end

return M
