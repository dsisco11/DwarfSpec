-- Public mount-command bindings for the run-scoped DwarfSpec namespace.

local M = {}

---Creates mount command implementations for one run-scoped namespace.
---@param dependencies table
---@return table
function M.new(dependencies)
    local context = dependencies.context
    return {
        ---Mounts one owned component or complete screen.
        mount=function(component, options, testbed_config)
            assert(component ~= nil, 'DwarfSpec ds.mount() requires a component; use ds.mountNativeScreen() to mount the current native DF screen')
            if type(component) == 'table' and component.kind ~= nil then
                return context.mount_context:mount_descriptor(component, options,
                    testbed_config)
            end
            assert(testbed_config == nil,
                'DwarfSpec class mount does not accept a third argument')
            if context.mount_context.boundary then
                local classification = context.mount_context.boundary:classify(component)
                assert(classification.input_form == 'class',
                    'DwarfSpec ds.mount() accepts a component class, not an instance')
            end
            return context.mount_context:mount(component, options)
        end,
        ---Mounts the current native DF screen without taking ownership of it.
        mountNativeScreen=function(...)
            assert(select('#', ...) == 0, 'DwarfSpec ds.mountNativeScreen() does not accept arguments')
            return context.mount_context:mount_native_screen(function()
                return dependencies.native_attachment:attach()
            end)
        end,
        ---Releases the current native attachment or mounted component.
        unmount=function() return context.mount_context:unmount() end,
        ---Invalidates a mounted screen and optionally awaits its render.
        redraw=function(view, options)
            local _, target = dependencies.resolve_target(view, 'redraw')
            assert(type(options) == 'table' or options == nil, 'redraw options must be a table')
            options = options or {}
            for name in pairs(options) do assert(name == 'wait', 'unsupported redraw option: ' .. tostring(name)) end
            assert(options.wait == nil or type(options.wait) == 'boolean', 'redraw wait option must be a boolean')
            return context.mount_context:mutate('redraw', function() return target:invalidate() end,
                {wait_for_render=options.wait ~= false})
        end,
        ---Changes the current mounted component viewport.
        viewport=function(width, height) return context.mount_context:viewport(width, height) end,
    }
end

return M
