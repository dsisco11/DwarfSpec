-- Direct contracts for mounted subject resolution.

local resolution = require(
    'dwarfspec.driver.mount.mount_subject_resolution')
local interaction_target = require(
    'dwarfspec.driver.subjects.interaction_target')
local native_widget_adapter = require(
    'dwarfspec.driver.subjects.native_widget_adapter')
local overlay_registry_adapter = require(
    'dwarfspec.driver.subjects.overlay_registry_adapter')

---Creates a resolution context backed by a mutable Lua-like tree.
---@return table, table, table
local function make_context()
    local child = {view_id='child', subviews={}}
    local root = {subviews={child}}
    local source
    local adapter = {
        root=function() return root end,
        children=function(_, view) return view.subviews or {} end,
        name=function(_, view) return view.view_id end,
        identity=function(_, view) return view end,
        contains=function(_, candidate)
            return candidate == root or candidate == child
        end,
        resolve=function(_, segments)
            local current = root
            for index, segment in ipairs(segments) do
                local found
                for _, candidate in ipairs(current.subviews or {}) do
                    if candidate.view_id == segment then found = candidate end
                end
                if not found then
                    return nil, {index=index, segment=segment, parent=current}
                end
                current = found
            end
            return current
        end,
        native_type=function() return 'widget' end,
        bounds=function() return {} end,
        visible=function() return true end,
        active=function() return true end,
        focused=function() return false end,
        text=function() return nil end,
        tooltip=function() return nil end,
        optional_fields=function() return {} end,
        inspect=function() return {} end,
    }
    source = {adapter=adapter}
    local mount = {
        id=2,
        alive=true,
        category='widget',
        root=root,
        subject_source=source,
        subject_sources={[source]=true},
        selected_subjects=setmetatable({}, {__mode='k'}),
        owned_views=setmetatable({}, {__mode='k'}),
    }
    local context = {
        current=mount,
        view_mounts=setmetatable({}, {__mode='k'}),
        subject_mounts=setmetatable({}, {__mode='k'}),
        subject_module={
            new=function(_, _, descriptor)
                return {
                    mount_id=descriptor.mount_id,
                    control_path=descriptor.control_path_for_diagnostics,
                    _descriptor=descriptor,
                }
            end,
        },
        require_current=function(self) return self.current end,
    }
    local service = resolution.new(context)
    service:refresh_views(mount)
    return service, root, child
end

describe('mount subject resolution', function()
    it('resolves Lua child paths and retains their identities', function()
        local context, _, child = make_context()
        assert.equals(child, context:resolve_control_path('child'))
        local selected = context:new_subject(child, 'child')
        assert.equals(child, context:resolve_subject(selected, 'raw access'))
        assert.equals(context.current.id, context:mount_for_view(child).id)
    end)

    it('resolves and retains actual overlay subjects with ambiguity rejection',
            function()
        local context = make_context()
        local child = {view_id='child', subviews={}}
        local root = {view_id='overlay-root', subviews={child}}
        local registry = {
            db={example={widget=root}},
            config={example={enabled=true}},
            index={'example'},
        }
        local overlay = overlay_registry_adapter.new_source('example', {
            get_state=function() return registry end,
        })
        context:register_subject_source(overlay)
        local resolved = context:resolve_path_segments(
            {'child'}, 'overlay:example/child', overlay)
        local retained = context:new_subject(
            resolved, 'overlay:example/child', {'child'}, overlay)
        assert.equals(child, context:resolve_subject(retained, 'inspect'))

        root.subviews = {
            {view_id='child', subviews={}},
            {view_id='child', subviews={}},
        }
        assert.has_error(function()
            context:resolve_path_segments(
                {'child'}, 'overlay:example/child', overlay)
        end, 'Lua view tree has multiple direct children named "child"')
        assert.has_error(function()
            context:resolve_subject(retained, 'inspect')
        end)
        root.subviews = {}
        assert.has_error(function()
            context:resolve_subject(retained, 'inspect')
        end)
    end)

    it('resolves actual native paths and rejects replacement and removal',
            function()
        local context = make_context()
        local screen = {}
        local current = screen
        local target = interaction_target.new_borrowed_native(screen, {
            get_current_viewscreen=function() return current end,
            invalidate_screen=function() end,
        })
        local child = {id='child-1', name='child', children={}}
        local root = {id='root', children={child}}
        local native = native_widget_adapter.new_source(root, target, {
            get_widget=function(parent, segment)
                local found
                for _, candidate in ipairs(parent.children or {}) do
                    if candidate.name == segment then
                        assert(found == nil, 'ambiguous native child')
                        found = candidate
                    end
                end
                return found
            end,
            get_children=function(parent) return parent.children or {} end,
            is_container=function(value) return value == root end,
            identity_of=function(value) return value.id end,
            name_of=function(value) return value.name end,
            type_of=function() return 'df.widget' end,
        })
        context.current.category = 'native'
        context.current.root = root
        context.current.interaction_target = target
        context.current.subject_source = native
        context.current.subject_sources = {[native]=true}
        context:refresh_views(context.current)
        local resolved = context:resolve_path_segments(
            {'child'}, 'native:child', native)
        local retained = context:new_subject(
            resolved, 'native:child', {'child'}, native)
        assert.equals(child, context:resolve_subject(retained, 'inspect'))

        root.children[1] = {id='child-2', name='child', children={}}
        assert.has_error(function()
            context:resolve_subject(retained, 'inspect')
        end)
        table.insert(root.children,
            {id='child-3', name='child', children={}})
        assert.has_error(function()
            context:resolve_path_segments(
                {'child'}, 'native:child', native)
        end)
        root.children = {}
        assert.has_error(function()
            context:resolve_subject(retained, 'inspect')
        end)
    end)

    it('rejects retained subjects after replacement or removal', function()
        local context, root, child = make_context()
        local selected = context:new_subject(child, 'child')
        root.subviews[1] = {view_id='child', subviews={}}
        context:refresh_views(context.current)
        assert.has_error(function()
            context:resolve_subject(selected, 'raw access')
        end)
        root.subviews = {}
        context:refresh_views(context.current)
        assert.has_error(function()
            context:resolve_subject(selected, 'raw access')
        end)
    end)

    it('rejects ambiguity in direct child identities', function()
        local context, root = make_context()
        root.subviews = {
            {view_id='same', subviews={}},
            {view_id='same', subviews={}},
        }
        assert.has_error(function() context:refresh_views(context.current) end,
            'DwarfSpec invalid component tree: parent control_path="<root>" ' ..
            'has multiple direct children with view_id="same"')
    end)

    it('bounds available-child diagnostics', function()
        local context, root = make_context()
        root.subviews = {}
        for index = 1, 14 do
            table.insert(root.subviews, {
                view_id=('child-%02d'):format(index),
                subviews={},
            })
        end
        context:refresh_views(context.current)
        local ok, failure = pcall(context.resolve_control_path, context, 'missing')
        assert.is_false(ok)
        assert.matches('child%-01, child%-02', failure)
        assert.matches('... (+2 more)', failure, 1, true)
        assert.is_nil(failure:find('child-13', 1, true))
    end)
end)
