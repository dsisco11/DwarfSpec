-- Unit contracts for native DF widget traversal and lookup diagnostics.

local interaction_target = require('dwarfspec.interaction_target')
local native_widget_adapter = require('dwarfspec.native_widget_adapter')

---Creates one native widget fixture with stable pointer-like identity.
---@param id string
---@param name string|nil
---@param type_name string
---@param children table[]|nil
---@param fields table|nil
---@return table
local function widget(id, name, type_name, children, fields)
    local value = {
        id=id,
        name=name,
        type_name=type_name,
        children=children or {},
    }
    for key, field in pairs(fields or {}) do value[key] = field end
    return value
end

describe('DwarfSpec native widget adapter', function()
    local screen
    local current
    local root
    local adapter
    local calls

    before_each(function()
        calls = {}
        screen = {}
        current = screen
        root = widget('root', nil, 'df.widget_container')
        local target = interaction_target.new_borrowed_native(screen, {
            get_current_viewscreen=function() return current end,
            invalidate_screen=function() end,
        })
        adapter = native_widget_adapter.new(root, target, {
            get_widget=function(parent, segment)
                table.insert(calls, {
                    operation='get',
                    parent=parent.id,
                    segment=segment,
                })
                if type(segment) == 'number' then
                    return parent.children[segment + 1]
                end
                for _, child in ipairs(parent.children) do
                    if child.name == segment then return child end
                end
                return nil
            end,
            get_children=function(parent)
                table.insert(calls, {
                    operation='children',
                    parent=parent.id,
                })
                local children = {}
                for index, child in ipairs(parent.children) do
                    children[index] = child
                end
                return children
            end,
            identity_of=function(raw) return raw.id end,
            name_of=function(raw) return raw.name end,
            type_of=function(raw) return raw.type_name end,
        })
    end)

    it('resolves named, indexed, mixed, and slash-bearing paths exactly',
            function()
        local slash = widget(
            'slash', 'Right/panel', 'df.widget_textst')
        local row = widget(
            'row', nil, 'df.widget_container', {slash})
        local tabs = widget(
            'tabs', 'Tabs', 'df.widget_container', {row})
        local hidden = widget(
            'hidden', 'Hidden', 'df.widget_textst', nil, {
                visible=false,
            })
        local inactive = widget(
            'inactive', 'Inactive', 'df.widget_textst', nil, {
                active=false,
            })
        root.children = {tabs, hidden, inactive}

        assert.equals(tabs, adapter:resolve({'Tabs'}))
        assert.equals(tabs, adapter:resolve({0}))
        assert.equals(slash,
            adapter:resolve({'Tabs', 0, 'Right/panel'}))
        assert.equals(hidden, adapter:resolve({'Hidden'}))
        assert.equals(inactive, adapter:resolve({'Inactive'}))
        assert.same({
            {operation='get', parent='root', segment='Tabs'},
            {operation='get', parent='root', segment=0},
            {operation='get', parent='root', segment='Tabs'},
            {operation='get', parent='tabs', segment=0},
            {
                operation='get',
                parent='row',
                segment='Right/panel',
            },
            {operation='get', parent='root', segment='Hidden'},
            {operation='get', parent='root', segment='Inactive'},
        }, calls)
        assert.same({tabs, hidden, inactive}, adapter:children(root))
    end)

    it('formats complete deterministic and bounded missing-child evidence',
            function()
        local children = {}
        for index = 0, 14 do
            table.insert(children, widget(
                ('child-%02d'):format(index),
                ('Child%02d'):format(index),
                'df.widget_textst'))
        end
        local parent = widget(
            'parent', 'Parent', 'df.widget_container', children)
        root.children = {parent}
        local path = {'Parent', 'Missing'}
        local resolved, failure = adapter:resolve(path)

        assert.is_nil(resolved)
        local first = adapter:format_resolution_failure(failure, path)
        local second = adapter:format_resolution_failure(failure, path)

        assert.equals(first, second)
        assert.matches('native_path={"Parent", "Missing"}',
            first, 1, true)
        assert.matches('missing segment%[2%]="Missing"', first)
        assert.matches('parent_name="Parent"', first, 1, true)
        assert.matches('parent_type="df.widget_container"',
            first, 1, true)
        assert.matches('"Child00":{index=0,type="df.widget_textst"}',
            first, 1, true)
        assert.matches('0:{name="Child00",type="df.widget_textst"}',
            first, 1, true)
        assert.matches('... (+3 more)', first, 1, true)
        assert.is_nil(first:find('Child12', 1, true))
    end)

    it('validates the pinned screen before invoking native services',
            function()
        local service_call_count = #calls
        current = {}

        assert.has_error(function()
            adapter:resolve({'Missing'})
        end, 'DwarfSpec native subject resolution rejected stale ' ..
            'native-screen mount; pinned viewscreen is no longer current')
        assert.has_error(function()
            adapter:children(root)
        end, 'DwarfSpec native child enumeration rejected stale ' ..
            'native-screen mount; pinned viewscreen is no longer current')
        assert.equals(service_call_count, #calls)
    end)

    it('uses stable injected identity across reacquired wrappers', function()
        local first = widget(
            'stable-pointer', 'Status', 'df.widget_textst')
        local second = widget(
            'stable-pointer', 'Status', 'df.widget_textst')
        root.children = {first}

        local initial = adapter:resolve({'Status'})
        local captured_identity = adapter:identity(initial)
        root.children = {second}
        local reacquired = adapter:resolve({'Status'})

        assert.is_not.equal(initial, reacquired)
        assert.equals(captured_identity, adapter:identity(reacquired))
        assert.is_true(adapter:contains(reacquired))
    end)
end)
