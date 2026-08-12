-- Adapter-backed references to one subject inside a run-owned mount.

local M = {}

---@class dwarfspec.SubjectDescriptor
---@field mount_id integer
---@field source dwarfspec.SubjectSource
---@field path_segments dwarfspec.NativePathSegment[]
---@field adapter dwarfspec.SubjectAdapter
---@field captured_identity any
---@field control_path_for_diagnostics string

---@class dwarfspec.Subject
---@field mount_id integer
---@field control_path string
---@field _descriptor dwarfspec.SubjectDescriptor|nil
---@field _references table
local Subject = {}
Subject.__index = Subject

---Invokes one command through the subject's current run-owned context.
---@param subject dwarfspec.Subject
---@param name string
---@param ... any
---@return any
local function invoke(subject, name, ...)
    local context = subject._references.context
    assert(context,
        'DwarfSpec subject is unavailable because its run has ended')
    assert(type(context.invoke_subject_command) == 'function',
        'DwarfSpec subject command context is unavailable')
    return context:invoke_subject_command(subject, name, ...)
end

---Invokes one verified read-only query without a legacy command wrapper.
---@param subject dwarfspec.Subject
---@param name string
---@param ... any
---@return any
local function invoke_query(subject, name, ...)
    local context = subject._references.context
    assert(context,
        'DwarfSpec subject is unavailable because its run has ended')
    assert(type(context.invoke_subject_query) == 'function',
        'DwarfSpec subject query context is unavailable')
    return context:invoke_subject_query(subject, name, ...)
end

---Clicks this subject and preserves it for fluent chaining.
---DwarfSpec automatically restores inherited pointer state during cleanup.
---It does not reverse game or UI effects caused by the click.
---@param button string|nil
---@return dwarfspec.Subject
function Subject:click(button)
    invoke(self, 'click', button)
    return self
end

---Moves the pointer over this subject and preserves it for fluent chaining.
---DwarfSpec automatically restores inherited pointer state during cleanup.
---@param anchor string|nil
---@param space any
---@return dwarfspec.Subject
function Subject:hover(anchor, space)
    assert(space == nil,
        'subject pointer commands use UI-grid coordinates and do not accept ' ..
        'a pointer space')
    invoke(self, 'hover', anchor)
    return self
end

---Moves the pointer to this subject and preserves it for fluent chaining.
---DwarfSpec automatically restores inherited pointer state during cleanup.
---@param anchor string|nil
---@param space any
---@return dwarfspec.Subject
function Subject:move_pointer(anchor, space)
    assert(space == nil,
        'subject pointer commands use UI-grid coordinates and do not accept ' ..
        'a pointer space')
    invoke(self, 'move_pointer', anchor)
    return self
end

---Sends a batch of wheel inputs over this subject and preserves fluent chaining.
---@param options table
---@return dwarfspec.Subject
function Subject:mouseWheel(options)
    invoke(self, 'mouseWheel', options)
    return self
end

---Sends native input through this subject's mounted screen.
---@param keys string|table
---@return dwarfspec.Subject
function Subject:input(keys)
    invoke(self, 'input', keys)
    return self
end

---Types text through this subject's mounted screen.
---@param text string
---@return dwarfspec.Subject
function Subject:type(text)
    invoke(self, 'type', text)
    return self
end

---Redraws this subject's mounted screen and optionally skips render wait.
---@param options table|nil
---@return dwarfspec.Subject
function Subject:redraw(options)
    invoke(self, 'redraw', options)
    return self
end

---Returns a stable diagnostic snapshot of this subject.
---@param command_options? table
---@return table
function Subject:inspect(command_options)
    return invoke_query(self, 'inspect', command_options)
end

---Searches final rendered screen cells within this subject's visible body.
---@param query dwarfspec.TextSearchQuery
---@param command_options? table
---@return dwarfspec.ScreenRect|nil
function Subject:search(query, command_options)
    return invoke_query(self, 'search', query, command_options)
end

---Returns a copied focus-string list for this subject's current mounted screen.
---@param command_options? table
---@return string[]
function Subject:getFocusList(command_options)
    return invoke_query(self, 'getFocusList', command_options)
end

---Returns the stable inspected text value for this subject.
---@param command_options? table
---@return string|nil
function Subject:text(command_options)
    local state = self:inspect(command_options)
    return state.text
end

---Returns the exact adapted object after validating current mount ownership.
---Native widget subjects return typed DF userdata; Lua views return tables.
---@param command_options? table
---@return table|userdata
function Subject:raw(command_options)
    return invoke_query(self, 'raw', command_options)
end

---Releases one retained descriptor after its owning mount is cleaned.
---@param subject dwarfspec.Subject
---@return boolean
function M.release(subject)
    assert(type(subject) == 'table',
        'subject release requires a subject table')
    if not subject._descriptor then return false end
    subject._descriptor = nil
    return true
end

---Copies path segments so caller mutation cannot retarget a subject.
---@param path_segments dwarfspec.NativePathSegment[]
---@return dwarfspec.NativePathSegment[]
local function copy_path(path_segments)
    local result = {}
    for index, segment in ipairs(path_segments) do result[index] = segment end
    return result
end

---Creates an adapter-backed subject descriptor for one mount.
---@param context table
---@param mount table
---@param descriptor dwarfspec.SubjectDescriptor
---@return dwarfspec.Subject
function M.new(context, mount, descriptor)
    assert(type(context) == 'table' and type(mount) == 'table',
        'subject requires an owning mount context')
    assert(type(descriptor) == 'table' and
        descriptor.mount_id == mount.id,
        'subject requires a descriptor for its owning mount')
    assert(type(descriptor.source) == 'table' and
        type(descriptor.adapter) == 'table',
        'subject descriptor requires a source and adapter')
    assert(type(descriptor.path_segments) == 'table',
        'subject descriptor requires path segments')
    assert(descriptor.captured_identity ~= nil,
        'subject descriptor requires captured identity')
    assert(type(descriptor.control_path_for_diagnostics) == 'string',
        'subject descriptor requires a diagnostic control path')
    local retained_descriptor = {
        mount_id=descriptor.mount_id,
        source=descriptor.source,
        path_segments=copy_path(descriptor.path_segments),
        adapter=descriptor.adapter,
        captured_identity=descriptor.captured_identity,
        control_path_for_diagnostics=
            descriptor.control_path_for_diagnostics,
    }
    local subject = setmetatable({
        mount_id=mount.id,
        control_path=retained_descriptor.control_path_for_diagnostics,
        _descriptor=retained_descriptor,
        _references=setmetatable({
            context=context,
            mount=mount,
        }, {__mode='v'}),
    }, Subject)
    return subject
end

return M
