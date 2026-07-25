-- Unit contracts for native DF widget traversal and lookup diagnostics.

local interaction_target = require('dwarfspec.interaction_target')
local native_widget_adapter = require('dwarfspec.native_widget_adapter')
local diagnostics = require('dwarfspec.automation.diagnostics')

---Creates one native widget fixture with stable pointer-like identity.
---@param id string
---@param name string|nil
---@param type_name string
---@param children table[]|nil
---@param fields table|nil
---@return table
local function widget(id, name, type_name, children, fields)
    fields = fields or {}
    local value = {
        id=id,
        name=name,
        type_name=type_name,
        children=children or {},
        flag={
            VISIBILITY_VISIBLE=fields.visible ~= false,
            VISIBILITY_ACTIVE=fields.active ~= false,
        },
    }
    for key, field in pairs(fields) do value[key] = field end
    for _, child in ipairs(value.children) do child.parent = value end
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
            is_container=function(raw)
                return raw.type_name == 'df.widget_container'
            end,
            get_window_size=function() return 80, 25 end,
            identity_of=function(raw) return raw.id end,
            name_of=function(raw) return raw.name end,
            type_of=function(raw) return raw.type_name end,
        })
    end)

    it('does not enumerate native leaf widgets as containers', function()
        local leaf = widget(
            'leaf', 'Leaf', 'df.widget_character', nil, {str='ignored'})
        root.children = {leaf}
        adapter:resolve({'Leaf'})

        assert.same({}, adapter:children(leaf))
        assert.is_nil(adapter:text(leaf))
        for _, call in ipairs(calls) do
            assert.is_false(
                call.operation == 'children' and call.parent == 'leaf')
        end
    end)

    it('normalizes live DFHack type descriptors for text inspection',
            function()
        local type_descriptor = setmetatable({}, {
            __tostring=function()
                return '<type: widget_text_multiline>'
            end,
        })
        local leaf = {
            _type=type_descriptor,
            name='Text',
            str='Native text',
            flag={
                VISIBILITY_VISIBLE=true,
                VISIBILITY_ACTIVE=true,
            },
        }
        local native_root = {
            _type=setmetatable({}, {
                __tostring=function()
                    return '<type: widget_container>'
                end,
            }),
            children={leaf},
            flag={
                VISIBILITY_VISIBLE=true,
                VISIBILITY_ACTIVE=true,
            },
        }
        leaf.parent = native_root
        local target = interaction_target.new_borrowed_native(screen, {
            get_current_viewscreen=function() return current end,
            invalidate_screen=function() end,
        })
        local default_adapter = native_widget_adapter.new(
            native_root, target, {
                get_widget=function(parent, segment)
                    for _, child in ipairs(parent.children or {}) do
                        if child.name == segment then return child end
                    end
                    return nil
                end,
                get_children=function(parent)
                    return parent.children or {}
                end,
                is_container=function(raw)
                    return raw == native_root
                end,
            })

        local resolved = default_adapter:resolve({'Text'})
        assert.equals('df.widget_text_multiline',
            default_adapter:native_type(resolved))
        assert.equals('Native text', default_adapter:text(resolved))
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
        assert.matches('stage=widget_traversal', first, 1, true)
        assert.matches('structural_prefix={}', first, 1, true)
        assert.matches(
            'widget_suffix={"Parent", "Missing"}', first, 1, true)
        assert.matches('kind=missing_widget', first, 1, true)
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
        assert.is_true(#first < 4096)
    end)

    it('preserves missing-widget evidence when child capture fails',
            function()
        local parent = widget(
            'parent', 'Parent', 'df.widget_container')
        root.children = {parent}
        local path = {'Parent', 'Missing'}
        local resolved, failure = adapter:resolve(path)
        adapter._get_children = function()
            error('diagnostic child enumeration failed')
        end

        local formatted =
            adapter:format_resolution_failure(failure, path)

        assert.is_nil(resolved)
        assert.matches('stage=widget_traversal', formatted, 1, true)
        assert.matches('kind=missing_widget', formatted, 1, true)
        assert.matches('missing segment%[2%]="Missing"', formatted)
        assert.matches(
            'diagnostic_capture_failed=true', formatted, 1, true)
        assert.is_nil(formatted:find(
            'diagnostic child enumeration failed', 1, true))

        current = {}
        local stale_capture =
            adapter:format_resolution_failure(failure, path)
        assert.matches('kind=missing_widget', stale_capture, 1, true)
        assert.matches(
            'diagnostic_capture_failed=true', stale_capture, 1, true)
        assert.is_nil(stale_capture:find(
            'pinned viewscreen is no longer current', 1, true))
    end)

    it('validates the pinned screen before invoking native services',
            function()
        local service_call_count = #calls
        current = {}

        local resolve_ok, resolve_failure = pcall(function()
            adapter:resolve({'Missing'})
        end)
        assert.is_false(resolve_ok)
        assert.matches('DwarfSpec native subject resolution rejected stale ' ..
            'native%-screen mount; pinned viewscreen is no longer current;',
            resolve_failure)
        local children_ok, children_failure = pcall(function()
            adapter:children(root)
        end)
        assert.is_false(children_ok)
        assert.matches('DwarfSpec native child enumeration rejected stale ' ..
            'native%-screen mount; pinned viewscreen is no longer current;',
            children_failure)
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

    it('reacquires a located root and its widget suffix by stable identity',
            function()
        local first_child = widget(
            'stable-child', 'Status', 'df.widget_textst')
        local first_root = widget(
            'stable-root', nil, 'df.widget_container', {first_child})
        local second_child = widget(
            'stable-child', 'Status', 'df.widget_textst')
        local second_root = widget(
            'stable-root', nil, 'df.widget_container', {second_child})
        local located_root = first_root
        local locator_calls = 0
        local located = native_widget_adapter.new(
            nil, adapter._interaction_target, {
                root_locator=function()
                    locator_calls = locator_calls + 1
                    return located_root
                end,
                structural_path={'info', 'creatures'},
                get_widget=function(parent, segment)
                    for _, child in ipairs(parent.children) do
                        if child.name == segment then return child end
                    end
                    return nil
                end,
                get_children=function(parent)
                    return parent.children
                end,
                is_container=function(raw)
                    return raw.type_name == 'df.widget_container'
                end,
                identity_of=function(raw) return raw.id end,
                name_of=function(raw) return raw.name end,
                type_of=function(raw) return raw.type_name end,
            })

        local initial = located:resolve({'Status'})
        located_root = second_root
        local reacquired = located:resolve({'Status'})

        assert.equals(first_child, initial)
        assert.equals(second_child, reacquired)
        assert.is_not.equal(initial, reacquired)
        assert.equals('stable-root', located:captured_root_identity())
        assert.equals('stable-child', located:identity(reacquired))
        assert.is_true(located:contains(reacquired))
        assert.equals(5, locator_calls)
    end)

    it('distinguishes removed, replaced, and failed located roots',
            function()
        local first_root = widget(
            'stable-root', nil, 'df.widget_container')
        local located_root = first_root
        local locator_failure
        local located = native_widget_adapter.new(
            first_root, adapter._interaction_target, {
                root_locator=function()
                    if locator_failure then error(locator_failure, 0) end
                    return located_root
                end,
                structural_path={'info', 'creatures'},
                get_widget=function() return nil end,
                get_children=function() return {} end,
                is_container=function() return true end,
                identity_of=function(raw) return raw.id end,
            })

        located_root = nil
        local removed_ok, removed =
            pcall(located.resolve, located, {'Status'})
        assert.is_false(removed_ok)
        assert.matches(
            'structural root no longer resolves', removed, 1, true)
        assert.matches(
            'stage=retained_subject_reacquisition',
            removed, 1, true)

        located_root = widget(
            'replacement-root', nil, 'df.widget_container')
        local replaced_ok, replaced =
            pcall(located.resolve, located, {'Status'})
        assert.is_false(replaced_ok)
        assert.matches(
            'structural root was replaced', replaced, 1, true)
        assert.matches(
            'captured_identity=string:stable%-root ' ..
                'current_identity=string:replacement%-root',
            replaced)

        located_root = first_root
        locator_failure = 'main interface access exploded'
        local failed_ok, failed =
            pcall(located.resolve, located, {'Status'})
        assert.is_false(failed_ok)
        assert.matches('because reacquisition failed:', failed, 1, true)
        assert.matches(
            'main interface access exploded', failed, 1, true)
    end)

    it('checks screen currentness before invoking a root locator', function()
        local located_root = widget(
            'stable-root', nil, 'df.widget_container')
        local locator_calls = 0
        local located = native_widget_adapter.new(
            located_root, adapter._interaction_target, {
                root_locator=function()
                    locator_calls = locator_calls + 1
                    return located_root
                end,
                structural_path={'info', 'creatures'},
                get_widget=function() return nil end,
                get_children=function() return {} end,
                is_container=function() return true end,
                identity_of=function(raw) return raw.id end,
            })
        local calls_after_creation = locator_calls
        current = {}

        local ok, failure =
            pcall(located.resolve, located, {'Status'})

        assert.is_false(ok)
        assert.matches(
            'pinned viewscreen is no longer current', failure, 1, true)
        assert.matches(
            'stage=retained_subject_reacquisition',
            failure, 1, true)
        assert.equals(calls_after_creation, locator_calls)
    end)

    it('releases located-root references without mutating native objects',
            function()
        local located_root = widget(
            'stable-root', nil, 'df.widget_container')
        located_root.dismissals = 0
        located_root.mutations = 0
        local located = native_widget_adapter.new(
            located_root, adapter._interaction_target, {
                root_locator=function() return located_root end,
                structural_path={'info', 'creatures'},
                get_widget=function() return nil end,
                get_children=function() return {} end,
                is_container=function() return true end,
                identity_of=function(raw) return raw.id end,
            })

        assert.is_true(located:cleanup())

        assert.is_nil(located._root)
        assert.is_nil(located._root_locator)
        assert.is_nil(located._root_identity)
        assert.is_nil(located._structural_path)
        assert.same({}, located._known_identities)
        assert.equals(0, located_root.dismissals)
        assert.equals(0, located_root.mutations)
        assert.is_false(located:cleanup())
    end)

    it('normalizes get_rect geometry and falls back to rect', function()
        local preferred = widget(
            'preferred', 'Preferred', 'df.widget', nil, {
                rect={x1=30, y1=30, x2=31, y2=31},
                get_rect=function()
                    return {x1=1, y1=2, x2=5, y2=7}
                end,
            })
        local fallback = widget(
            'fallback', 'Fallback', 'df.widget', nil, {
                rect={x1=-2, y1=3, x2=4, y2=9},
            })
        root.children = {preferred, fallback}

        adapter:resolve({'Preferred'})
        adapter:resolve({'Fallback'})
        assert.same({x1=1, y1=2, x2=5, y2=7},
            adapter:bounds(preferred))
        assert.same({x1=-2, y1=3, x2=4, y2=9},
            adapter:bounds(fallback))
        assert.same({x1=0, y1=3, x2=4, y2=9},
            adapter:interaction_bounds(fallback))
    end)

    it('keeps invalid and off-window widgets inspectable but not interactive',
            function()
        local invalid = widget(
            'invalid', 'Invalid', 'df.widget', nil, {
                rect={x1=4, y1=3, x2=2, y2=5},
            })
        local fractional = widget(
            'fractional', 'Fractional', 'df.widget', nil, {
                rect={x1=1.5, y1=1, x2=4, y2=5},
            })
        local offscreen = widget(
            'offscreen', 'Offscreen', 'df.widget', nil, {
                rect={x1=90, y1=30, x2=100, y2=40},
            })
        root.children = {invalid, fractional, offscreen}
        for _, child in ipairs(root.children) do
            adapter:resolve({child.name})
            assert.is_table(adapter:inspect(child))
            assert.is_nil(adapter:interaction_bounds(child))
        end
        assert.is_nil(adapter:bounds(invalid))
        assert.is_nil(adapter:bounds(fractional))
        assert.same({x1=90, y1=30, x2=100, y2=40},
            adapter:bounds(offscreen))
    end)

    it('reports all direct visibility and activity combinations', function()
        local combinations = {
            {true, true},
            {true, false},
            {false, true},
            {false, false},
        }
        for index, values in ipairs(combinations) do
            local child = widget(
                'flags-' .. index, 'Flags' .. index, 'df.widget', nil, {
                    visible=values[1],
                    active=values[2],
                })
            child.parent = root
            table.insert(root.children, child)
            adapter:resolve({child.name})
            assert.equals(values[1], adapter:visible(child))
            assert.equals(values[2], adapter:active(child))
        end
    end)

    it('keeps direct and effective inherited state separate', function()
        local parent = widget(
            'parent', 'Parent', 'df.widget_container', nil, {
                visible=false,
                active=true,
            })
        local child = widget(
            'child', 'Child', 'df.widget_text', nil, {
                visible=true,
                active=false,
            })
        root.children = {parent}
        parent.parent = root
        parent.children = {child}
        child.parent = parent

        adapter:resolve({'Parent', 'Child'})
        local inspection = adapter:inspect(child)
        assert.is_true(inspection.visible)
        assert.is_false(inspection.active)
        assert.is_false(inspection.effective_visible)
        assert.is_false(inspection.effective_active)
    end)

    it('extracts only registered native text forms', function()
        local types = {
            'df.widget_text',
            'df.widget_text_truncated',
            'df.widget_text_multiline',
            'df.widget_textbox',
        }
        for index, type_name in ipairs(types) do
            local child = widget(
                'text-' .. index, 'Text' .. index, type_name, nil, {
                    str='value-' .. index,
                })
            table.insert(root.children, child)
            adapter:resolve({child.name})
            assert.equals('value-' .. index, adapter:text(child))
        end
        local unsupported = widget(
            'unsupported', 'Unsupported', 'df.widget_character', nil, {
                str='must not leak',
            })
        table.insert(root.children, unsupported)
        adapter:resolve({'Unsupported'})
        assert.is_nil(adapter:text(unsupported))

        local long = widget(
            'long', 'Long', 'df.widget_text', nil, {
                str=string.rep('x', 600),
            })
        table.insert(root.children, long)
        adapter:resolve({'Long'})
        assert.equals(512, #adapter:text(long))
        assert.equals('...', adapter:text(long):sub(-3))
    end)

    it('uses the better-button display accessor without invoking callbacks',
            function()
        local display_calls = 0
        local mutation_calls = 0
        local button = widget(
            'button', 'Button', 'df.widget_better_button', nil, {
                display_string=function()
                    display_calls = display_calls + 1
                    return 'Safe display'
                end,
                on_activate=function() mutation_calls = mutation_calls + 1 end,
                on_input=function() mutation_calls = mutation_calls + 1 end,
                tooltip=function() mutation_calls = mutation_calls + 1 end,
            })
        root.children = {button}
        adapter:resolve({'Button'})

        local inspection = adapter:inspect(button)
        assert.equals('Safe display', inspection.text)
        assert.equals(1, display_calls)
        assert.equals(0, mutation_calls)
        assert.is_nil(inspection.tooltip)
    end)

    it('aggregates visible descendant text within deterministic bounds',
            function()
        local visible = widget(
            'visible', 'Visible', 'df.widget_text', nil, {str='visible'})
        local hidden = widget(
            'hidden', 'Hidden', 'df.widget_text', nil, {
                str='hidden',
                visible=false,
            })
        local nested_text = widget(
            'nested-text', 'NestedText', 'df.widget_text', nil, {
                str='nested',
            })
        local nested = widget(
            'nested', 'Nested', 'df.widget_container', {nested_text})
        local container = widget(
            'container', 'Container', 'df.widget_container',
            {visible, hidden, nested})
        root.children = {container}
        container.parent = root

        adapter:resolve({'Container'})
        assert.equals('visible\nnested', adapter:text(container))
    end)

    it('exposes only documented bounded optional fields', function()
        local rows = widget(
            'rows', 'Rows', 'df.widget_scroll_rows', nil, {
                scroll=12,
                num_visible=8,
                secret={unbounded=true},
                tooltip='Rows tooltip',
            })
        local tabs = widget(
            'tabs', 'Tabs', 'df.widget_tabs', nil, {cur_idx=3})
        local dropdown = widget(
            'dropdown', 'Dropdown', 'df.widget_dropdown', nil, {
                cur_selected=4,
            })
        local radio = widget(
            'radio', 'Radio', 'df.widget_radio_rows', nil, {
                selected_idx=5,
            })
        root.children = {rows, tabs, dropdown, radio}
        rows.parent = root
        tabs.parent = root
        dropdown.parent = root
        radio.parent = root
        adapter:resolve({'Rows'})
        adapter:resolve({'Tabs'})
        adapter:resolve({'Dropdown'})
        adapter:resolve({'Radio'})

        local rows_inspection = adapter:inspect(rows)
        assert.equals('df.widget_scroll_rows',
            rows_inspection.native_type)
        assert.equals('Rows', rows_inspection.name)
        assert.equals('Rows tooltip', rows_inspection.tooltip)
        assert.equals(12, rows_inspection.scroll_position)
        assert.equals(8, rows_inspection.visible_row_count)
        assert.is_nil(rows_inspection.secret)
        assert.equals(3, adapter:inspect(tabs).selected_index)
        assert.equals(4, adapter:inspect(dropdown).selected_index)
        assert.equals(5, adapter:inspect(radio).selected_index)
    end)

    it('captures native trees deterministically within every bound', function()
        for index = 1, 10 do
            table.insert(root.children, widget(
                'tree-' .. index,
                'Tree' .. index,
                'df.widget_text',
                nil,
                {str=string.rep(tostring(index % 10), 30)}))
        end

        local options = {
            max_depth=2,
            max_nodes=20,
            max_children=3,
            max_value_length=16,
        }
        local first = diagnostics.capture_view_tree(root, options, adapter)
        local second = diagnostics.capture_view_tree(root, options, adapter)

        assert.same(first, second)
        assert.equals(3, #first.children)
        assert.is_true(first.truncated)
        assert.is_true(first.capture_bounds.truncated)
        assert.equals(16, #first.text)
        assert.equals(4, first.capture_bounds.node_count)
    end)
end)
