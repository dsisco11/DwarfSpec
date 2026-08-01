-- Unit contracts for adapter-backed Lua gui.View subjects.

local lua_view_adapter = assert(loadfile(
    'src/dwarfspec/driver/subjects/lua_view_adapter.lua'))()

describe('Lua view subject adapter', function()
    it('resolves, identifies, inspects, and bounds the existing view model',
            function()
        local leaf = {
            view_id='leaf',
            visible=function() return true end,
            active=function() return false end,
            focus=true,
            frame_rect={x1=1, y1=2, x2=9, y2=10},
            frame_body={x1=2, y1=3, x2=8, y2=9},
            text=42,
            tooltip='tip',
            subviews={},
        }
        local panel = {
            view_id='panel',
            visible=true,
            active=true,
            subviews={leaf},
        }
        local root = {subviews={panel}}
        local source = lua_view_adapter.new_source(root)
        local adapter = source.adapter

        assert.equals(root, adapter:root())
        assert.equals(panel, adapter:resolve({'panel'}))
        assert.equals(leaf, adapter:resolve({'panel', 'leaf'}))
        assert.equals(leaf, adapter:identity(leaf))
        assert.is_true(adapter:contains(root))
        assert.is_true(adapter:contains(leaf))
        assert.is_false(adapter:contains({}))
        assert.same({panel}, adapter:children(root))
        assert.equals('leaf', adapter:name(leaf))
        assert.equals('table', adapter:native_type(leaf))
        assert.equals(leaf.frame_body, adapter:bounds(leaf))
        assert.is_true(adapter:visible(leaf))
        assert.is_false(adapter:active(leaf))
        assert.is_true(adapter:focused(leaf))
        assert.equals('42', adapter:text(leaf))
        assert.equals('tip', adapter:tooltip(leaf))
        assert.same({}, adapter:optional_fields(leaf))
        assert.same({
            class='table',
            view_id='leaf',
            visible=true,
            active=false,
            focused=true,
            frame={
                x1=1, y1=2, x2=9, y2=10,
            },
            body={
                x1=2, y1=3, x2=8, y2=9,
            },
            text='42',
            tooltip='tip',
        }, adapter:inspect(leaf))

        local missing, failure = adapter:resolve({'panel', 'missing'})
        assert.is_nil(missing)
        assert.equals(2, failure.index)
        assert.equals('missing', failure.segment)
        assert.equals(panel, failure.parent)
    end)

    it('releases only adapter references and leaves views unchanged',
            function()
        local child = {view_id='child', subviews={}}
        local root = {subviews={child}}
        local adapter = lua_view_adapter.new(root)

        assert.is_true(adapter:cleanup())
        assert.is_false(adapter:cleanup())
        assert.same({child}, root.subviews)
        assert.has_error(function() adapter:root() end,
            'Lua view subject source is no longer available')
        assert.is_false(adapter:contains(child))
    end)

    it('exposes bounded DFHack list scroll state', function()
        local list = {
            view_id='list',
            visible=true,
            active=true,
            page_top=7,
            page_size=12,
            choices={'one', 'two'},
            subviews={},
        }
        local adapter = lua_view_adapter.new(list)

        assert.same({
            scroll_position=7,
            visible_row_count=12,
        }, adapter:optional_fields(list))
        local inspection = adapter:inspect(list)
        assert.equals(7, inspection.scroll_position)
        assert.equals(12, inspection.visible_row_count)
        assert.is_nil(inspection.choices)
    end)
end)
