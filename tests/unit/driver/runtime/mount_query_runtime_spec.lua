local MountQueryRuntime = require(
    'dwarfspec.driver.runtime.mount_query_runtime')

describe('mount query runtime capability', function()
    it('owns component root, get, inspect, and capture operations', function()
        local root_view = {name='root'}
        local child_view = {name='child'}
        local adapter = {root=function() return root_view end}
        local source = {kind='component', adapter=adapter}
        local mount = {id=7, subject_source=source}
        local captured
        local context = {
            require_current=function(_, operation)
                assert.is_truthy(operation)
                return mount
            end,
            root=function() return {kind='root-subject'} end,
            resolve_control_path=function(_, path)
                assert.equals('child', path)
                return child_view
            end,
            new_subject=function(_, view, path, segments, selected_source)
                return {view=view, path=path, segments=segments,
                    source=selected_source}
            end,
        }
        local runtime = MountQueryRuntime.new({
            mount_context=context,
            subject_sources={
                select=function() error('unexpected source selection') end,
                resolve_implicit_path=function()
                    error('unexpected implicit path resolution')
                end,
            },
            subject_source={NATIVE='native'},
            requests={},
            paths={},
            target_resolver={resolve=function(_, value, operation)
                assert.equals('inspect', operation)
                return value, nil, nil, adapter
            end},
            diagnostics={
                inspect_view=function(view, selected_adapter)
                    assert.equals(child_view, view)
                    assert.equals(adapter, selected_adapter)
                    return {inspected=true}
                end,
                capture_view_tree=function(view, _, selected_adapter)
                    assert.equals(root_view, view)
                    assert.equals(adapter, selected_adapter)
                    return {captured=true}
                end,
            },
            run={},
        })

        assert.same({kind='root-subject'}, runtime:root())
        local subject = runtime:get('child')
        assert.equals(child_view, subject.view)
        assert.same({inspected=true}, runtime:inspect(child_view))
        captured = runtime:capture_view_tree('component')
        assert.same({captured=true}, captured)
    end)
end)
