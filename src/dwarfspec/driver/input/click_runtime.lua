-- Cohesive run-scoped target, input, and render support for verified clicks.

---@class dwarfspec.ClickRuntime
---@field private _resolver dwarfspec.InteractionTargetResolver
---@field private _dispatch fun(subject:table, button:string):any|nil
---@field private _move_pointer function|nil
---@field private _mutate function|nil
---@field private _pointer table|nil
---@field private _pointer_adapter table|nil
---@field private _simulate_input function|nil
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
    assert(options.dispatch == nil or type(options.dispatch) == 'function',
        'click runtime input dispatch must be callable')
    if options.dispatch == nil then
        for _, name in ipairs({'move_pointer', 'mutate', 'simulate_input'}) do
            assert(type(options[name]) == 'function',
                'click runtime requires ' .. name)
        end
        assert(type(options.pointer) == 'table',
            'click runtime requires pointer state')
        assert(type(options.pointer_adapter) == 'table' and
                type(options.pointer_adapter.with_mouse_focus) == 'function' and
                type(options.pointer_adapter.sync) == 'function',
            'click runtime requires a pointer adapter')
    end
    return setmetatable({_resolver=options.resolver,
        _dispatch=options.dispatch, _move_pointer=options.move_pointer,
        _mutate=options.mutate, _pointer=options.pointer,
        _pointer_adapter=options.pointer_adapter,
        _simulate_input=options.simulate_input}, ClickRuntime)
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
    if self._dispatch then return self._dispatch(subject, button) end
    local _, target = self._resolver:resolve(subject, 'click')
    local key = ({left='_MOUSE_L', right='_MOUSE_R',
        middle='_MOUSE_M'})[button or 'left']
    assert(key, 'unsupported mouse button: ' .. tostring(button))
    self._move_pointer(subject)
    return self._mutate('click', function()
        self._pointer_adapter.with_mouse_focus(self._pointer, function()
            self._pointer_adapter.sync(self._pointer)
            self._simulate_input(target, 'click', key)
        end)
    end)
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
