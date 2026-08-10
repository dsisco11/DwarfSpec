-- Cohesive run-scoped target, input, and render support for verified clicks.

---@class dwarfspec.ClickRuntime
---@field private _resolver dwarfspec.InteractionTargetResolver
---@field private _dispatch fun(subject:table, button:string):any
local ClickRuntime = {}
ClickRuntime.__index = ClickRuntime

---Creates click runtime support around mounted input capabilities.
---@param options table
---@return dwarfspec.ClickRuntime
function ClickRuntime.new(options)
    assert(type(options) == 'table', 'click runtime options are required')
    assert(type(options.resolver) == 'table' and
            type(options.resolver.resolve) == 'function',
        'click runtime requires an interaction-target resolver')
    assert(type(options.dispatch) == 'function',
        'click runtime requires input dispatch')
    return setmetatable({_resolver=options.resolver,
        _dispatch=options.dispatch}, ClickRuntime)
end

---Resolves the subject and current input target immediately before dispatch.
---@param subject table
---@return table
function ClickRuntime:resolve(subject)
    local view, target = self._resolver:resolve(subject, 'click')
    return {subject=subject, view=view, target=target,
        target_identity=subject.control_path}
end

---Dispatches one click through the existing mount-owned input path.
---@param subject table
---@param button string
---@return any
function ClickRuntime:dispatch(subject, button)
    return self._dispatch(subject, button)
end

---Captures the render generation immediately before input dispatch.
---@param context table
---@return number
function ClickRuntime:capture_render(context)
    return context:capture_render()
end

---Observes whether the render generation following a click has settled.
---@param context table
---@param prior_generation number
---@return boolean
function ClickRuntime:observe_render(context, prior_generation)
    return context:observe_render(prior_generation)
end

return ClickRuntime
