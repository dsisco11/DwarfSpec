-- Mounted subject registration, traversal, and retained identity.

local subject_paths = require('dwarfspec.driver.subjects.subject_paths')
local ESubjectSource = require('dwarfspec.driver.subjects.subject_sources')
local EResolutionStage =
    require('dwarfspec.driver.subjects.native_resolution_stages')
local identity_labels = require('dwarfspec.support.identity_labels')

local M = {}

---Returns the bounded semantic kind for one adapted subject source.
---@param source dwarfspec.SubjectSource
---@return string
local function source_kind(source)
    if type(source.kind) == 'string' and source.kind ~= '' then
        return source.kind
    end
    return 'component'
end

---Constructs subject resolution with an explicitly bounded dependency scope.
---@param scope table
---@return table
function M.new(scope)
    local service = {}
    ---Formats one parent identity for control-path validation errors.
    ---@param control_path string|nil
    ---@return string
    local function parent_identity(control_path)
        if control_path == '' then return '<root>' end
        return control_path or '<anonymous>'
    end

    ---Returns the validated selected or default adapter for one mount.
    ---@param mount table
    ---@param source dwarfspec.SubjectSource|nil
    ---@return dwarfspec.SubjectAdapter
    local function subject_adapter(mount, source)
        source = source or (mount and mount.subject_source)
        local adapter = source and source.adapter
        assert(type(adapter) == 'table' and
            type(adapter.root) == 'function' and
            type(adapter.resolve) == 'function' and
            type(adapter.identity) == 'function' and
            type(adapter.contains) == 'function' and
            type(adapter.children) == 'function' and
            type(adapter.name) == 'function' and
            type(adapter.native_type) == 'function' and
            type(adapter.bounds) == 'function' and
            type(adapter.visible) == 'function' and
            type(adapter.active) == 'function' and
            type(adapter.focused) == 'function' and
            type(adapter.text) == 'function' and
            type(adapter.tooltip) == 'function' and
            type(adapter.optional_fields) == 'function' and
            type(adapter.inspect) == 'function',
            'mounted subject adapter is incomplete')
        return adapter
    end

    ---Returns the validated adapter shared with mount construction.
    ---@param mount table
    ---@param source dwarfspec.SubjectSource|nil
    ---@return dwarfspec.SubjectAdapter
    function service:adapter_for(mount, source)
        return subject_adapter(mount, source)
    end

    ---Returns whether a mount uses the pinned native widget source.
    ---@param mount table
    ---@param source dwarfspec.SubjectSource|nil
    ---@return boolean
    local function uses_native_subjects(mount, source)
        source = source or (mount and mount.subject_source)
        return mount and source and source.kind == ESubjectSource.NATIVE
    end

    ---Returns whether a source is an externally owned overlay registry root.
    ---@param source dwarfspec.SubjectSource|nil
    ---@return boolean
    local function uses_overlay_subjects(source)
        return source and source.kind == ESubjectSource.OVERLAY
    end

    ---Refreshes weak ownership and validates direct child control identities.
    ---@param mount table
    function service:refresh_views(mount)
        assert(type(mount) == 'table' and not mount.cleaned,
            'cannot refresh a cleaned component mount')
        local adapter = subject_adapter(mount)
        local native_subjects = uses_native_subjects(mount)
        local owned_views = setmetatable({}, {__mode='k'})
        local visited = setmetatable({}, {__mode='k'})

        ---Records one view and validates each of its direct child IDs.
        ---@param view table
        ---@param control_path string|nil
        local function visit(view, control_path)
            if visited[view] then return end
            visited[view] = true
            owned_views[view] = true
            if native_subjects then
                for _, child in ipairs(adapter:children(view)) do
                    visit(child, nil)
                end
            else
                local child_ids = {}
                for _, child in ipairs(adapter:children(view)) do
                    local child_id = adapter:name(child)
                    local child_path = nil
                    if type(child_id) == 'string' and child_id ~= '' then
                        assert(not child_id:find('/', 1, true),
                            ('DwarfSpec invalid component tree: parent ' ..
                            'control_path=%q has child view_id=%q ' ..
                            'containing "/"'):format(
                                parent_identity(control_path), child_id))
                        assert(child_id ~= '.' and child_id ~= '..',
                            ('DwarfSpec invalid component tree: parent ' ..
                            'control_path=%q has reserved child view_id=%q')
                                :format(parent_identity(control_path),
                                    child_id))
                        assert(not child_ids[child_id],
                            ('DwarfSpec invalid component tree: parent ' ..
                            'control_path=%q has multiple direct children ' ..
                            'with view_id=%q'):format(
                                parent_identity(control_path), child_id))
                        child_ids[child_id] = true
                        if control_path ~= nil then
                            child_path = control_path == '' and child_id or
                                control_path .. '/' .. child_id
                        end
                    end
                    visit(child, child_path)
                end
            end
        end

        local root = adapter:root()
        assert(root == mount.root,
            'mounted subject source root changed during mount')
        visit(root, '')
        for view in pairs(mount.owned_views) do
            if self.view_mounts[view] == mount.id then
                self.view_mounts[view] = nil
            end
        end
        for view in pairs(owned_views) do self.view_mounts[view] = mount.id end
        mount.owned_views = owned_views
    end

    ---Formats the available direct child control IDs for one resolution error.
    ---@param view table
    ---@param adapter dwarfspec.SubjectAdapter
    ---@return string
    local function available_child_ids(view, adapter)
        local ids = {}
        for _, child in ipairs(adapter:children(view)) do
            local child_id = adapter:name(child)
            if type(child_id) == 'string' and child_id ~= '' then
                table.insert(ids, child_id)
            end
        end
        table.sort(ids)
        local limit = 12
        local visible = {}
        for index, child_id in ipairs(ids) do
            if index > limit then break end
            table.insert(visible, child_id)
        end
        if #ids > limit then
            table.insert(visible, ('... (+%d more)'):format(#ids - limit))
        end
        return #visible > 0 and table.concat(visible, ', ') or '<none>'
    end

    ---Parses one strict component-relative control path.
    ---@param control_path string
    ---@return string[]
    local function parse_control_path(control_path)
        return subject_paths.component(control_path)
    end

    ---Resolves one strict path by walking direct mounted-component children.
    ---@param control_path string
    ---@return table
    function service:resolve_control_path(control_path)
        local segments = parse_control_path(control_path)
        return self:resolve_path_segments(segments, control_path)
    end

    ---Resolves normalized source-specific path segments through one adapter.
    ---@param segments dwarfspec.NativePathSegment[]
    ---@param diagnostic_path string
    ---@param source dwarfspec.SubjectSource|nil
    ---@return any
    function service:resolve_path_segments(segments, diagnostic_path, source)
        local mount = self:require_current('get')
        assert(type(segments) == 'table',
            'subject path resolution requires normalized segments')
        assert(type(diagnostic_path) == 'string' and diagnostic_path ~= '',
            'subject path resolution requires a diagnostic path')
        source = source or mount.subject_source
        assert(mount.subject_sources[source],
            'subject source is not registered with the current mount')
        local adapter = subject_adapter(mount, source)
        local view, failure = adapter:resolve(segments)
        if view then return view end
        if uses_native_subjects(mount, source) and
                type(adapter.format_resolution_failure) == 'function' then
            assert(false, ('DwarfSpec get failed: mount=%s %s')
                :format(tostring(mount.id),
                    adapter:format_resolution_failure(
                        failure, segments, diagnostic_path)))
        end
        local resolved = {}
        for index = 1, failure.index - 1 do
            table.insert(resolved, segments[index])
        end
        local resolved_path = table.concat(resolved, '/')
        assert(false,
             ('DwarfSpec get failed: control_path=%q mount=%s missing ' ..
             'segment=%q after=%q; available children=%s')
                :format(diagnostic_path, tostring(mount.id), failure.segment,
                    parent_identity(resolved_path),
                    available_child_ids(failure.parent, adapter)))
    end

    ---Returns the current mount that owns a native view, if any.
    ---@param view table
    ---@return table|nil
    function service:mount_for_view(view)
        local mount = self.current
        if mount and self.view_mounts[view] == mount.id then return mount end
        return nil
    end
    ---Registers one externally owned subject source with the current mount.
    ---@param source dwarfspec.SubjectSource
    ---@return dwarfspec.SubjectSource
    function service:register_subject_source(source)
        local mount = self:require_current('subject source selection')
        assert(type(source) == 'table',
            'subject source selection requires a source table')
        local candidate_adapter = subject_adapter(mount, source)
        if source.kind == ESubjectSource.NATIVE and
                type(candidate_adapter.same_located_root) == 'function' then
            for registered in pairs(mount.subject_sources) do
                local registered_adapter = subject_adapter(mount, registered)
                if registered ~= source and
                        registered.kind == ESubjectSource.NATIVE and
                        candidate_adapter:same_located_root(
                            registered_adapter) then
                    if type(candidate_adapter.cleanup) == 'function' then
                        candidate_adapter:cleanup()
                    end
                    return registered
                end
            end
        end
        mount.subject_sources[source] = true
        return source
    end

    ---Creates and weakly tracks one subject in the current mount.
    ---@param view table
    ---@param control_path string|nil
    ---@param path_segments dwarfspec.NativePathSegment[]|nil
    ---@param source dwarfspec.SubjectSource|nil
    ---@return table
    function service:new_subject(view, control_path, path_segments, source)
        local mount = self:require_current('subject creation')
        source = source or mount.subject_source
        assert(mount.subject_sources[source],
            'subject source is not registered with the current mount')
        local adapter = subject_adapter(mount, source)
        assert(adapter:contains(view) and
            (uses_native_subjects(mount, source) or
                uses_overlay_subjects(source) or
                self.view_mounts[view] == mount.id),
            'subject view is outside the current mount')
        local diagnostic_path = control_path or '<root>'
        path_segments = path_segments or
            (diagnostic_path == '<root>' and {} or
                parse_control_path(diagnostic_path))
        local subject = self.subject_module.new(self.subject_context, mount, {
            mount_id=mount.id,
            source=source,
            path_segments=path_segments,
            adapter=adapter,
            captured_identity=adapter:identity(view),
            control_path_for_diagnostics=diagnostic_path,
        })
        self.subject_mounts[subject] = mount.id
        mount.selected_subjects[subject] = true
        return subject
    end

    ---Resolves a subject only while its original mount remains current.
    ---@param subject table
    ---@param operation string
    ---@return table
    function service:resolve_subject(subject, operation)
        local mount = self.current
        assert(mount and mount.alive,
            ('stage=%s DwarfSpec %s rejected stale subject ' ..
                'control_path=%q from mount %s; no current mount exists')
                :format(
                    EResolutionStage.RETAINED_SUBJECT_REACQUISITION,
                    operation, subject.control_path,
                    tostring(subject.mount_id)))
        assert(self.subject_mounts[subject] == mount.id and
            subject.mount_id == mount.id,
            ('stage=%s DwarfSpec %s rejected stale subject ' ..
                'control_path=%q from mount %s; current mount is %s')
                :format(
                    EResolutionStage.RETAINED_SUBJECT_REACQUISITION,
                    operation, subject.control_path,
                    tostring(subject.mount_id), tostring(mount.id)))
        local descriptor = subject._descriptor
        assert(descriptor and mount.subject_sources[descriptor.source] and
            descriptor.adapter == subject_adapter(
                mount, descriptor.source),
            ('stage=%s DwarfSpec %s subject control_path=%q mount=%s ' ..
            'descriptor is no longer available'):format(
                EResolutionStage.RETAINED_SUBJECT_REACQUISITION,
                operation, subject.control_path, tostring(subject.mount_id)))
        if mount.category == 'native' then
            mount.interaction_target:assert_current(operation, {
                mount_kind=mount.category,
                source=source_kind(descriptor.source),
                path=subject.control_path,
                mount_id=subject.mount_id,
            })
        end
        local view = descriptor.adapter:resolve(descriptor.path_segments)
        if uses_native_subjects(mount, descriptor.source) then
            if not view then
                error(('stage=%s DwarfSpec %s rejected stale native ' ..
                    'subject path=%s ' ..
                    'mount=%s because the widget no longer resolves; call ' ..
                    'ds.get(path) to select it again; mount_kind=%q ' ..
                    'source=%q captured_identity=%s current_identity=%s')
                    :format(
                        EResolutionStage.RETAINED_SUBJECT_REACQUISITION,
                        operation, subject.control_path,
                        tostring(subject.mount_id), mount.category,
                        source_kind(descriptor.source),
                        identity_labels.of(descriptor.captured_identity),
                        identity_labels.of(nil)), 0)
            end
            local current_identity = descriptor.adapter:identity(view)
            if current_identity ~= descriptor.captured_identity then
                error(('stage=%s DwarfSpec %s rejected stale native ' ..
                    'subject path=%s ' ..
                    'mount=%s because the widget was replaced; call ' ..
                    'ds.get(path) to select the replacement; mount_kind=%q ' ..
                    'source=%q captured_identity=%s current_identity=%s')
                    :format(
                        EResolutionStage.RETAINED_SUBJECT_REACQUISITION,
                        operation, subject.control_path,
                        tostring(subject.mount_id), mount.category,
                        source_kind(descriptor.source),
                        identity_labels.of(descriptor.captured_identity),
                        identity_labels.of(current_identity)), 0)
            end
            if not descriptor.adapter:contains(view) then
                error(('stage=%s DwarfSpec %s rejected native subject ' ..
                    'path=%s ' ..
                    'mount=%s because the widget is outside the pinned ' ..
                    'hierarchy; mount_kind=%q source=%q captured_identity=%s ' ..
                    'current_identity=%s'):format(
                        EResolutionStage.RETAINED_SUBJECT_REACQUISITION,
                        operation, subject.control_path,
                        tostring(subject.mount_id),
                        mount.category, source_kind(descriptor.source),
                        identity_labels.of(descriptor.captured_identity),
                        identity_labels.of(current_identity)), 0)
            end
            return view
        end
        local current_identity = view and descriptor.adapter:identity(view)
        if not (view and
                current_identity == descriptor.captured_identity and
                descriptor.adapter:contains(view) and
                (uses_overlay_subjects(descriptor.source) or
                    self.view_mounts[view] == mount.id)) then
            error(('DwarfSpec %s rejected subject control_path=%q mount=%s ' ..
                'because its view is outside the current mount; ' ..
                'mount_kind=%q source=%q captured_identity=%s ' ..
                'current_identity=%s'):format(operation,
                    subject.control_path, tostring(subject.mount_id),
                    mount.category, source_kind(descriptor.source),
                    identity_labels.of(descriptor.captured_identity),
                    identity_labels.of(current_identity)), 0)
        end
        return view
    end
    return setmetatable(service, {__index=scope, __newindex=scope})
end

return M
