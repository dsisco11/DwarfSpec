-- Pinned Busted 2.3.0 file-suite lifecycle adapter.

local path = require('pl.path')
local FileSuiteIdentity =
    require('dwarfspec.automation.file_suite_identity')

local M = {}

local SUPPORTED_BUSTED_VERSION = '2.3.0'

---@class BustedLifecycleAdapterOptions
---@field project_root string
---@field on_suite_entry fun(identity: DwarfSpecFileSuiteIdentity): any
---@field on_suite_exit fun(identity: DwarfSpecFileSuiteIdentity, state: any)
---@field on_test_start fun(identity: BustedExampleIdentity)|nil

---@class BustedExampleIdentity
---@field example_name string
---@field source_identity string|nil

---Returns a slash-normalized absolute path.
---@param value string
---@return string
local function absolute_path(value)
    return path.abspath(value):gsub('\\', '/'):gsub('/+$', '')
end

---Returns whether path comparison should ignore character case.
---@return boolean
local function has_case_insensitive_paths()
    return package.config:sub(1, 1) == '\\'
end

---Returns a comparison-safe form of one normalized absolute path.
---@param value string
---@return string
local function comparable_path(value)
    if has_case_insensitive_paths() then return value:lower() end
    return value
end

---Returns a normalized project-relative identity for one Busted file.
---@param project_root string
---@param file_name string
---@return string
local function project_relative_file(project_root, file_name)
    local root = absolute_path(project_root)
    local file = absolute_path(file_name)
    local comparable_root = comparable_path(root)
    local comparable_file = comparable_path(file)
    local prefix = comparable_root .. '/'
    assert(comparable_file:sub(1, #prefix) == prefix,
        'Busted file is outside the project root: ' .. file_name)
    local relative = file:sub(#root + 2)
    assert(relative ~= '' and relative ~= '.' and relative ~= '..' and
        not relative:match('^%.%./') and
        not relative:match('/%.%./') and
        not relative:match('/%.%.$'),
        'Busted file has an invalid project-relative identity: ' .. file_name)
    return relative
end

---Returns one Busted context's complete example name.
---@param busted table
---@param element table
---@return string
local function full_example_name(busted, element)
    local names = {element.name or element.descriptor}
    local parent = busted.context.parent(element)
    while parent and (parent.name or parent.descriptor) and
            parent.descriptor ~= 'file' do
        table.insert(names, 1, parent.name or parent.descriptor)
        parent = busted.context.parent(parent)
    end
    return table.concat(names, ' ')
end

---Returns a project-relative source identity when Busted provides one.
---@param project_root string
---@param element table
---@return string|nil
local function example_source_identity(project_root, element)
    local trace = type(element.trace) == 'table' and element.trace or {}
    local source = element.source or element.short_src or trace.source or
        trace.short_src
    if type(source) ~= 'string' or source == '' then return nil end
    source = source:gsub('^@', '')
    local ok, relative = pcall(
        project_relative_file, project_root, source)
    if not ok then return nil end
    return relative
end

---Installs file-suite callbacks on one fresh Busted 2.3.0 runtime.
---@param busted table
---@param options BustedLifecycleAdapterOptions
function M.install(busted, options)
    assert(type(busted) == 'table' and
        type(busted.subscribe) == 'function',
        'Busted lifecycle adapter requires a Busted runtime')
    assert(busted.version == SUPPORTED_BUSTED_VERSION,
        'Busted lifecycle adapter requires Busted ' ..
        SUPPORTED_BUSTED_VERSION)
    assert(type(options) == 'table',
        'Busted lifecycle adapter options must be a table')
    assert(type(options.project_root) == 'string' and
        options.project_root ~= '',
        'Busted lifecycle adapter project root must be a nonempty string')
    assert(type(options.on_suite_entry) == 'function',
        'Busted lifecycle adapter suite-entry callback is required')
    assert(type(options.on_suite_exit) == 'function',
        'Busted lifecycle adapter suite-exit callback is required')

    local repeat_index = 1
    local repeat_count = 1
    local instance_index = 0
    local active

    ---Records the current outer repeat without creating a suite guard.
    ---@param _ table
    ---@param current_repeat integer
    ---@param total_repeats integer
    local function on_repeat_start(_, current_repeat, total_repeats)
        repeat_index = current_repeat
        repeat_count = total_repeats
        return nil, true
    end

    ---Creates one file-suite identity before the file body executes.
    ---@param file table
    local function on_file_start(file)
        assert(active == nil,
            'Busted file suites must execute sequentially')
        assert(type(file) == 'table' and type(file.name) == 'string',
            'Busted file start did not provide a named file context')
        instance_index = instance_index + 1
        local source_identity = project_relative_file(
            options.project_root, file.name)
        local identity = FileSuiteIdentity.new({
            suite_id=source_identity .. '#repeat=' ..
                tostring(repeat_index) .. '#instance=' ..
                tostring(instance_index),
            suite_name=source_identity,
            source_identity=source_identity,
            repeat_index=repeat_index,
            repeat_count=repeat_count,
        })
        active = {
            file=file,
            identity=identity,
        }
        active.state = options.on_suite_entry(identity:copy())
        return nil, true
    end

    ---Releases one file-suite identity before invoking its exit callback.
    ---@param file table
    local function on_file_end(file)
        assert(active ~= nil and rawequal(active.file, file),
            'Busted file end did not match the active file suite')
        local completed = active
        active = nil
        options.on_suite_exit(
            completed.identity:copy(), completed.state)
        return nil, true
    end

    ---Retains detached attribution for an example whose hooks succeeded.
    ---@param element table
    local function on_test_start(element)
        if options.on_test_start ~= nil then
            options.on_test_start({
                example_name=full_example_name(busted, element),
                source_identity=example_source_identity(
                    options.project_root, element),
            })
        end
        return nil, true
    end

    busted.subscribe(
        {'suite', 'start'}, on_repeat_start, {priority=1})
    busted.subscribe(
        {'file', 'start'}, on_file_start, {priority=1})
    busted.subscribe(
        {'file', 'end'}, on_file_end, {priority=1})
    if options.on_test_start ~= nil then
        assert(type(options.on_test_start) == 'function',
            'Busted lifecycle adapter test-start callback must be a function')
        busted.subscribe(
            {'test', 'start'}, on_test_start, {priority=1})
    end
end

---Validates the pinned Busted example-hook surface.
---@param busted table
local function validate_example_hooks(busted)
    assert(type(busted) == 'table' and
        busted.version == SUPPORTED_BUSTED_VERSION and
        type(busted.api) == 'table',
        'Busted lifecycle adapter requires Busted ' ..
        SUPPORTED_BUSTED_VERSION)
    assert(type(busted.api.before_each) == 'function' and
        type(busted.api.after_each) == 'function',
        'Busted lifecycle adapter requires example hook APIs')
end

---Installs one root-scoped callback before project example setup.
---@param busted table
---@param callback function
function M.install_example_entry(busted, callback)
    validate_example_hooks(busted)
    assert(type(callback) == 'function',
        'Busted lifecycle adapter example-entry callback is required')
    busted.api.before_each(callback)
end

---Installs one root-scoped callback after all project example teardown.
---@param busted table
---@param callback function
function M.install_example_exit(busted, callback)
    validate_example_hooks(busted)
    assert(type(callback) == 'function',
        'Busted lifecycle adapter example-exit callback is required')
    busted.api.after_each(callback)
end

return M
