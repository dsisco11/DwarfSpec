-- Weak, run-owned references to one component inside a mount.

local M = {}

---@class dwarfspec.Subject
---@field mount_id integer
---@field view_id string
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

---Clicks this subject and preserves it for fluent chaining.
---@param button string|nil
---@return dwarfspec.Subject
function Subject:click(button)
    invoke(self, 'click', button)
    return self
end

---Moves the pointer over this subject and preserves it for fluent chaining.
---@param anchor string|nil
---@return dwarfspec.Subject
function Subject:hover(anchor)
    invoke(self, 'hover', anchor)
    return self
end

---Moves the pointer to this subject and preserves it for fluent chaining.
---@param anchor string|nil
---@return dwarfspec.Subject
function Subject:move_pointer(anchor)
    invoke(self, 'move_pointer', anchor)
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

---Returns a stable diagnostic snapshot of this subject.
---@return table
function Subject:inspect()
    return invoke(self, 'inspect')
end

---Returns the stable inspected text value for this subject.
---@return string|nil
function Subject:text()
    local state = self:inspect()
    return state.text
end

---Returns the native object after validating current mount ownership.
---@return table
function Subject:raw()
    local context = self._references.context
    assert(context,
        'DwarfSpec subject is unavailable because its run has ended')
    return context:resolve_subject(self, 'subject raw access')
end

---Creates a weak subject for a native object in one mount.
---@param context table
---@param mount table
---@param view table
---@param view_id string|nil
---@return dwarfspec.Subject
function M.new(context, mount, view, view_id)
    assert(type(context) == 'table' and type(mount) == 'table',
        'subject requires an owning mount context')
    assert(type(view) == 'table', 'subject requires a native component object')
    local subject = setmetatable({
        mount_id=mount.id,
        view_id=view_id or view.view_id or '<root>',
        _references=setmetatable({
            context=context,
            mount=mount,
            view=view,
        }, {__mode='v'}),
    }, Subject)
    return subject
end

return M
