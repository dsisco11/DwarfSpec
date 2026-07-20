-- Weak, run-owned references to one component inside a mount.

local M = {}

---@class dwarfspec.Subject
---@field mount_id integer
---@field _references table
local Subject = {}
Subject.__index = Subject

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
---@return dwarfspec.Subject
function M.new(context, mount, view)
    assert(type(context) == 'table' and type(mount) == 'table',
        'subject requires an owning mount context')
    assert(type(view) == 'table', 'subject requires a native component object')
    local subject = setmetatable({
        mount_id=mount.id,
        _references=setmetatable({
            context=context,
            mount=mount,
            view=view,
        }, {__mode='v'}),
    }, Subject)
    return subject
end

return M
