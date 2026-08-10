-- Run-scoped interaction-target resolution for mounted subjects.

---@class dwarfspec.InteractionTargetResolver
---@field private _mount_context table
local InteractionTargetResolver = {}
InteractionTargetResolver.__index = InteractionTargetResolver

---Creates a resolver bound to one run's mount context.
---@param mount_context table
---@return dwarfspec.InteractionTargetResolver
function InteractionTargetResolver.new(mount_context)
    assert(type(mount_context) == 'table' and
            type(mount_context.require_current) == 'function' and
            type(mount_context.resolve_subject) == 'function' and
            type(mount_context.is_subject) == 'function',
        'interaction-target resolver requires a mount context')
    return setmetatable({_mount_context=mount_context},
        InteractionTargetResolver)
end

---Resolves an optional subject against the current mount.
---@param value table|nil
---@param operation string
---@return any, any, table, table
function InteractionTargetResolver:resolve(value, operation)
    if value == nil then
        local mount = self._mount_context:require_current(operation)
        local adapter = mount.subject_source.adapter
        return adapter:root(), mount.interaction_target, mount, adapter
    end
    if self._mount_context:is_subject(value) then
        local view = self._mount_context:resolve_subject(value, operation)
        local mount = self._mount_context.current
        return view, mount.interaction_target, mount,
            value._descriptor.adapter
    end
    error(('DwarfSpec %s requires a subject from the current mount; ' ..
        'use ds.get(control_path) or ds.root()'):format(operation), 2)
end

return InteractionTargetResolver
