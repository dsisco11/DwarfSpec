-- Public mount-command bindings for the run-scoped DwarfSpec namespace.

local M = {}

---Creates mount command implementations for one run-scoped namespace.
---@param dependencies table
---@return table
function M.new(dependencies)
    local context = dependencies.context
    local function require_mount(operation)
        return context.mount_context:require_current(operation)
    end
    local function root(options)
        local mount = require_mount('root')
        if mount.subject_source.kind ~= dependencies.subject_source.NATIVE then
            assert(options == nil, 'component mounts do not accept subject source options')
            return context.mount_context:root()
        end
        local source = dependencies.select_source(mount,
            dependencies.requests.root(options))
        if source == mount.subject_source then return context.mount_context:root() end
        return context.mount_context:new_subject(source.adapter:root(), '<root>', {}, source)
    end
    local function get(control_path, options)
        local mount = require_mount('get')
        local path_segments, diagnostic_path = nil, control_path
        local source = mount.subject_source
        local implicit_native = false
        if source.kind == dependencies.subject_source.NATIVE then
            local request = dependencies.requests.get(control_path, options)
            source = dependencies.select_source(mount, request)
            path_segments = request.path_segments
            implicit_native = request.source == dependencies.subject_source.NATIVE and request.native_root == nil
            if request.source == dependencies.subject_source.NATIVE then
                diagnostic_path = dependencies.paths.format_native(path_segments)
            end
        else
            assert(options == nil, 'component mounts do not accept subject source options')
        end
        local previous = mount.command_subject
        mount.command_subject = {mount_id=mount.id, control_path=diagnostic_path}
        local ok, selected = pcall(function()
            if implicit_native then
                return dependencies.resolve_implicit_path(mount, path_segments, diagnostic_path)
            end
            if path_segments then
                return {view=context.mount_context:resolve_path_segments(path_segments, diagnostic_path, source),
                    source=source, path_segments=path_segments}
            end
            return {view=context.mount_context:resolve_control_path(control_path),
                source=source, path_segments=nil}
        end)
        if not ok then
            local reported = context.mount_context:report_failure(mount, 'get', selected)
            mount.command_subject = previous
            error(reported, 2)
        end
        mount.command_subject = previous
        return context.mount_context:new_subject(selected.view, diagnostic_path,
            selected.path_segments, selected.source)
    end
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
        root=root,
        get=get,
        ---Releases the current native attachment or mounted component.
        unmount=function() return context.mount_context:unmount() end,
        ---Returns stable diagnostics for a selected mounted subject.
        inspect=function(view)
            local selected, _, _, adapter = dependencies.resolve_target(view, 'inspect')
            return dependencies.diagnostics.inspect_view(selected, adapter)
        end,
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
        ---Captures the selected subject-source tree under an evidence name.
        capture_view_tree=function(name, options)
            local mount = require_mount('capture_view_tree')
            local source = mount.subject_source
            if source.kind == dependencies.subject_source.NATIVE then
                source = dependencies.select_source(mount, dependencies.requests.tree(options))
            else
                assert(options == nil, 'component mounts do not accept subject source options')
            end
            assert(type(name) == 'string' and name:match('^[%w_.-]+$'), 'capture name must be a relative identifier')
            context.run.captures = context.run.captures or {}
            local tree = dependencies.diagnostics.capture_view_tree(source.adapter:root(), nil, source.adapter)
            context.run.captures[name] = tree
            return tree
        end,
        ---Changes the current mounted component viewport.
        viewport=function(width, height) return context.mount_context:viewport(width, height) end,
    }
end

return M
