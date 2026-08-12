-- Cohesive current-mount query capability.

---@class dwarfspec.MountQueryRuntime
---@field private _mount_context table
---@field private _subject_sources table
---@field private _subject_source table
---@field private _requests table
---@field private _paths table
---@field private _target_resolver table
---@field private _diagnostics table
---@field private _run table
local MountQueryRuntime = {}
MountQueryRuntime.__index = MountQueryRuntime

---Creates the current-mount query capability.
---@param options table
---@return dwarfspec.MountQueryRuntime
function MountQueryRuntime.new(options)
    assert(type(options) == 'table',
        'mount-query runtime options are required')
    for _, name in ipairs({'mount_context', 'subject_sources',
            'subject_source', 'requests', 'paths', 'target_resolver',
            'diagnostics', 'run'}) do
        assert(type(options[name]) == 'table',
            'mount-query runtime requires ' .. name)
    end
    assert(type(options.subject_sources.select) == 'function',
        'mount-query runtime requires subject-source selection')
    assert(type(options.subject_sources.resolve_implicit_path) == 'function',
        'mount-query runtime requires implicit path resolution')
    assert(type(options.target_resolver.resolve) == 'function',
        'mount-query runtime requires interaction-target resolution')
    return setmetatable({
        _mount_context=options.mount_context,
        _subject_sources=options.subject_sources,
        _subject_source=options.subject_source,
        _requests=options.requests,
        _paths=options.paths,
        _target_resolver=options.target_resolver,
        _diagnostics=options.diagnostics,
        _run=options.run,
    }, MountQueryRuntime)
end

---Requires the current mount for one query operation.
---@param operation string
---@return table
function MountQueryRuntime:preflight(operation)
    return self._mount_context:require_current(operation)
end

---Returns the selected current-mount root.
---@param options? table
---@return table
function MountQueryRuntime:root(options)
    local mount = self._mount_context:require_current('root')
    if mount.subject_source.kind ~= self._subject_source.NATIVE then
        assert(options == nil,
            'component mounts do not accept subject source options')
        return self._mount_context:root()
    end
    local source = self._subject_sources.select(mount,
        self._requests.root(options))
    if source == mount.subject_source then return self._mount_context:root() end
    return self._mount_context:new_subject(source.adapter:root(), '<root>', {},
        source)
end

---Returns one subject from the current mount.
---@param control_path any
---@param options? table
---@return table
function MountQueryRuntime:get(control_path, options)
    local mount = self._mount_context:require_current('get')
    local path_segments, diagnostic_path = nil, control_path
    local source = mount.subject_source
    local implicit_native = false
    if source.kind == self._subject_source.NATIVE then
        local request = self._requests.get(control_path, options)
        source = self._subject_sources.select(mount, request)
        path_segments = request.path_segments
        implicit_native = request.source == self._subject_source.NATIVE and
            request.native_root == nil
        if request.source == self._subject_source.NATIVE then
            diagnostic_path = self._paths.format_native(path_segments)
        end
    else
        assert(options == nil,
            'component mounts do not accept subject source options')
    end
    local previous = mount.command_subject
    mount.command_subject = {
        mount_id=mount.id,
        control_path=diagnostic_path,
    }
    local ok, selected = pcall(function()
        if implicit_native then
            return self._subject_sources.resolve_implicit_path(mount,
                path_segments, diagnostic_path)
        end
        if path_segments then
            return {
                view=self._mount_context:resolve_path_segments(path_segments,
                    diagnostic_path, source),
                source=source,
                path_segments=path_segments,
            }
        end
        return {
            view=self._mount_context:resolve_control_path(control_path),
            source=source,
            path_segments=nil,
        }
    end)
    if not ok then
        local reported = self._mount_context:report_failure(mount, 'get',
            selected)
        mount.command_subject = previous
        error(reported, 2)
    end
    mount.command_subject = previous
    return self._mount_context:new_subject(selected.view, diagnostic_path,
        selected.path_segments, selected.source)
end

---Returns stable diagnostics for one subject.
---@param view? table
---@return table
function MountQueryRuntime:inspect(view)
    local selected, _, _, adapter = self._target_resolver:resolve(view,
        'inspect')
    return self._diagnostics.inspect_view(selected, adapter)
end

---Captures one bounded current-mount tree.
---@param name string
---@param options? table
---@return table
function MountQueryRuntime:capture_view_tree(name, options)
    local mount = self._mount_context:require_current('capture_view_tree')
    local source = mount.subject_source
    if source.kind == self._subject_source.NATIVE then
        source = self._subject_sources.select(mount,
            self._requests.tree(options))
    else
        assert(options == nil,
            'component mounts do not accept subject source options')
    end
    assert(type(name) == 'string' and name:match('^[%w_.-]+$'),
        'capture name must be a relative identifier')
    self._run.captures = self._run.captures or {}
    local tree = self._diagnostics.capture_view_tree(source.adapter:root(),
        nil, source.adapter)
    self._run.captures[name] = tree
    return tree
end

return MountQueryRuntime
