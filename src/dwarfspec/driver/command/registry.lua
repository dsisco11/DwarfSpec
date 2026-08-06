-- Deterministic immutable command-definition registry.

local Definition = require('dwarfspec.driver.command.definition')

---@class dwarfspec.CommandRegistry
---@field private _definitions table<string, dwarfspec.CommandDefinition>
---@field private _built_in_names table<string, true>
---@field private _reserved_names table<string, true>
local Registry = {}
Registry.__index = Registry

---@class dwarfspec.driver.command.RegistryInternals
local Internals = {}

---Copies a set or array of reserved command names.
---@param names? table
---@return table<string, true>
function Internals.name_set(names)
    local result = {}
    for key, value in pairs(names or {}) do
        local name = type(key) == 'number' and value or key
        assert(type(name) == 'string' and name ~= '',
            'reserved command names must be nonempty strings')
        result[name] = true
    end
    return result
end

---Formats a project-definition diagnostic prefix.
---@param source_path any
---@param command_name any
---@return string
function Internals.project_label(source_path, command_name)
    local source = type(source_path) == 'string' and source_path ~= '' and
        source_path or '<unknown source>'
    local name = type(command_name) == 'string' and command_name ~= '' and
        command_name or '<unknown command>'
    return ('project command %q from %q'):format(name, source)
end

---Creates an empty registry with optional permanently reserved names.
---@param options? table
---@return dwarfspec.CommandRegistry
function Registry.new(options)
    options = options or {}
    return setmetatable({
        _definitions={},
        _built_in_names={},
        _reserved_names=Internals.name_set(options.reserved_names),
    }, Registry)
end

---Registers one built-in definition and reserves its name from projects.
---@param definition table
---@return dwarfspec.CommandDefinition
function Registry:register_builtin(definition)
    local accepted = Definition.validate(definition)
    assert(not self._definitions[accepted.name],
        ('duplicate command name %q'):format(accepted.name))
    self._definitions[accepted.name] = accepted
    self._built_in_names[accepted.name] = true
    return accepted
end

---Registers one project definition with source-aware failures.
---@param definition table
---@param source_path string
---@return dwarfspec.CommandDefinition
function Registry:register_project(definition, source_path)
    local name = type(definition) == 'table' and definition.name or nil
    local label = Internals.project_label(source_path, name)
    assert(type(source_path) == 'string' and source_path ~= '',
        label .. ': source_path must be a nonempty string')
    assert(not (name and (self._reserved_names[name] or
        self._built_in_names[name])), label .. ': reserved built-in name')
    assert(not (name and self._definitions[name]),
        label .. ': duplicate command name')
    local succeeded, accepted = pcall(Definition.validate, definition)
    assert(succeeded, label .. ': ' .. tostring(accepted))
    self._definitions[accepted.name] = accepted
    return accepted
end

---Merges built-ins and source-tagged projects in deterministic name order.
---@param builtins table[]
---@param projects table[] Entries contain definition and source_path.
function Registry:merge(builtins, projects)
    assert(type(builtins) == 'table' and type(projects) == 'table',
        'registry merge requires built-in and project arrays')
    local ordered_builtins = {}
    for index, definition in ipairs(builtins) do
        ordered_builtins[index] = definition
    end
    table.sort(ordered_builtins, function(left, right)
        return tostring(left.name) < tostring(right.name)
    end)
    for _, definition in ipairs(ordered_builtins) do
        self:register_builtin(definition)
    end
    local ordered_projects = {}
    for index, entry in ipairs(projects) do ordered_projects[index] = entry end
    table.sort(ordered_projects, function(left, right)
        local left_key = tostring(left.source_path) .. '\0' ..
            tostring(left.definition and left.definition.name)
        local right_key = tostring(right.source_path) .. '\0' ..
            tostring(right.definition and right.definition.name)
        return left_key < right_key
    end)
    for _, entry in ipairs(ordered_projects) do
        self:register_project(entry.definition, entry.source_path)
    end
end

---Returns one immutable definition by name, or nil when absent.
---@param name string
---@return dwarfspec.CommandDefinition|nil
function Registry:get(name)
    assert(type(name) == 'string' and name ~= '',
        'command name must be a nonempty string')
    return self._definitions[name]
end

---Returns registered command names in lexical order.
---@return string[]
function Registry:names()
    local names = {}
    for name in pairs(self._definitions) do names[#names + 1] = name end
    table.sort(names)
    return names
end

return Registry
