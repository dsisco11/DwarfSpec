-- Unit contracts for deterministic native game-UI structural path resolution.

local native_game_ui_path = require('dwarfspec.native_game_ui_path')

local EFieldMode = native_game_ui_path.EFieldMode
local EFieldKind = native_game_ui_path.EFieldKind
local EFailureKind = native_game_ui_path.EFailureKind
local EResolutionStage = native_game_ui_path.EResolutionStage

---Creates one declared field description.
---@param name string
---@param kind DwarfSpecEGameUIFieldKind
---@return table
local function field(name, kind)
    return {name=name, kind=kind}
end

---Creates an isolated resolver fixture whose objects cannot be indexed.
---@return table
local function fixture()
    local state = {
        types={},
        fields={},
        field_orders={},
        values={},
        widgets={},
        containers={},
        children={},
        identities={},
        calls={
            get_type={},
            get_fields={},
            read_field={},
            get_widget={},
        },
        mutation_count=0,
    }

    ---Creates one opaque userdata-like fixture object.
    ---@param id string
    ---@param options table|nil
    ---@return table
    function state:object(id, options)
        options = options or {}
        local value = setmetatable({}, {
            __index=function(_, name)
                error('arbitrary object indexing attempted: ' .. tostring(name))
            end,
        })
        local type_name = options.type_name or ('type.' .. id)
        self.types[value] = type_name
        self.fields[type_name] = options.fields or {}
        self.field_orders[type_name] = {}
        for name in pairs(options.fields or {}) do
            table.insert(self.field_orders[type_name], name)
        end
        self.values[value] = {}
        self.widgets[value] = options.widget == true
        self.containers[value] = options.container == true
        self.children[value] = {}
        self.identities[value] = options.identity or id
        return value
    end

    ---Adds one exact declared field and its stored value.
    ---@param parent table
    ---@param name string
    ---@param kind DwarfSpecEGameUIFieldKind
    ---@param value any
    ---@return table
    function state:add_field(parent, name, kind, value)
        local metadata = field(name, kind)
        self.fields[self.types[parent]][name] = metadata
        table.insert(self.field_orders[self.types[parent]], name)
        self.values[parent][metadata] = value
        return metadata
    end

    ---Adds one directly named or indexed native widget child.
    ---@param parent table
    ---@param segment string|integer
    ---@param child table
    function state:add_widget(parent, segment, child)
        self.children[parent][segment] = child
    end

    state.main = state:object('main')
    state.impl = {
        get_main_interface=function()
            return state.main
        end,
        get_type=function(value)
            table.insert(state.calls.get_type, value)
            return state.types[value]
        end,
        get_fields=function(type_name)
            table.insert(state.calls.get_fields, type_name)
            return state.fields[type_name], state.field_orders[type_name]
        end,
        read_field=function(parent, metadata)
            table.insert(state.calls.read_field, {
                parent=parent,
                metadata=metadata,
            })
            return state.values[parent][metadata]
        end,
        is_widget=function(value)
            return state.widgets[value] == true
        end,
        is_container=function(value)
            return state.containers[value] == true
        end,
        get_widget=function(parent, segment)
            table.insert(state.calls.get_widget, {
                parent=parent,
                segment=segment,
            })
            return state.children[parent][segment]
        end,
        identity_of=function(value)
            return state.identities[value]
        end,
    }

    ---Builds a resolver over the fixture's replaceable injected services.
    ---@return dwarfspec.NativeGameUIPathResolver
    function state:resolver()
        local options = {}
        for _, name in ipairs({
            'get_main_interface',
            'get_type',
            'get_fields',
            'read_field',
            'is_widget',
            'is_container',
            'get_widget',
            'identity_of',
        }) do
            options[name] = function(...)
                return self.impl[name](...)
            end
        end
        return native_game_ui_path.new(options)
    end

    return state
end

describe('DwarfSpec native game-UI path resolver', function()
    it('resolves one structural field followed by one widget', function()
        local f = fixture()
        local container = f:object(
            'container', {widget=true, container=true})
        local leaf = f:object('leaf', {widget=true})
        f:add_field(
            f.main, 'container', EFieldKind.WIDGET, container)
        f:add_widget(container, 'Leaf', leaf)

        local result = f:resolver():resolve({'container', 'Leaf'})

        assert.is_nil(result.failure)
        assert.same({'container'}, result.structural_segments)
        assert.same({'Leaf'}, result.widget_segments)
        assert.equals(leaf, result.widget)
    end)

    it('splits nested structural fields from the widget suffix', function()
        local f = fixture()
        local info = f:object('info')
        local creatures = f:object(
            'creatures', {widget=true, container=true})
        local tabs = f:object('tabs', {widget=true, container=true})
        local missing = f:object(
            'dead-missing', {widget=true, container=true})
        f:add_field(f.main, 'info', EFieldKind.COMPOUND, info)
        f:add_field(
            info, 'creatures', EFieldKind.WIDGET, creatures)
        f:add_widget(creatures, 'Tabs', tabs)
        f:add_widget(tabs, 'Dead/Missing', missing)
        local path = {'info', 'creatures', 'Tabs', 'Dead/Missing'}

        local result = f:resolver():resolve(path)

        assert.is_nil(result.failure)
        assert.same(path, result.path)
        assert.is_not.equal(path, result.path)
        assert.same({'info', 'creatures'}, result.structural_segments)
        assert.same({'Tabs', 'Dead/Missing'}, result.widget_segments)
        assert.equals(creatures, result.widget_root)
        assert.equals('creatures', result.widget_root_identity)
        assert.equals(missing, result.widget)
        assert.equals('dead-missing', result.widget_identity)
        assert.equals(2, #f.calls.read_field)
        assert.same({
            {parent=creatures, segment='Tabs'},
            {parent=tabs, segment='Dead/Missing'},
        }, f.calls.get_widget)
    end)

    it('resolves declared DF field names containing underscores and digits',
            function()
        local f = fixture()
        local final = f:object('final', {widget=true})
        f:add_field(
            f.main, 'unit_list2', EFieldKind.WIDGET, final)

        local result = f:resolver():resolve({'unit_list2'})

        assert.is_nil(result.failure)
        assert.same({'unit_list2'}, result.structural_segments)
        assert.same({}, result.widget_segments)
        assert.equals(final, result.widget)
    end)

    it('continues through declared fields on a widget container', function()
        local f = fixture()
        local container = f:object(
            'container', {widget=true, container=true})
        local nested = f:object(
            'nested', {widget=true, container=true})
        local leaf = f:object('leaf', {widget=true})
        f:add_field(
            f.main, 'container', EFieldKind.WIDGET, container)
        f:add_field(
            container, 'nested', EFieldKind.WIDGET, nested)
        f:add_widget(nested, 'Leaf', leaf)

        local result =
            f:resolver():resolve({'container', 'nested', 'Leaf'})

        assert.is_nil(result.failure)
        assert.same(
            {'container', 'nested'}, result.structural_segments)
        assert.same({'Leaf'}, result.widget_segments)
    end)

    it('never returns to field traversal after the widget transition',
            function()
        local f = fixture()
        local container = f:object(
            'container', {widget=true, container=true})
        local tabs = f:object('tabs', {widget=true, container=true})
        local widget_child = f:object('widget-child', {widget=true})
        local field_child = f:object('field-child', {widget=true})
        f:add_field(
            f.main, 'container', EFieldKind.WIDGET, container)
        f:add_field(
            tabs, 'SameName', EFieldKind.WIDGET, field_child)
        f:add_widget(container, 'Tabs', tabs)
        f:add_widget(tabs, 'SameName', widget_child)

        local result = f:resolver():resolve({
            'container',
            'Tabs',
            'SameName',
        })

        assert.is_nil(result.failure)
        assert.equals(widget_child, result.widget)
        assert.same({'container'}, result.structural_segments)
        assert.same({'Tabs', 'SameName'}, result.widget_segments)
        assert.equals(1, #f.calls.read_field)
    end)

    it('allows zero-based integer segments only after widget transition',
            function()
        local f = fixture()
        local container = f:object(
            'container', {widget=true, container=true})
        local row = f:object('row', {widget=true})
        f:add_field(
            f.main, 'container', EFieldKind.WIDGET, container)
        f:add_widget(container, 0, row)

        local success = f:resolver():resolve({'container', 0})
        local failure = f:resolver():resolve({0})

        assert.is_nil(success.failure)
        assert.same({0}, success.widget_segments)
        assert.equals(row, success.widget)
        assert.equals(
            EFailureKind.INVALID_STRUCTURAL_SEGMENT,
            failure.failure.kind)
        assert.equals(1, failure.failure.index)
        assert.equals(0, failure.failure.segment)
    end)

    it('rejects invalid and empty complete paths deterministically',
            function()
        local f = fixture()
        local nil_result = f:resolver():resolve(nil)
        local cases = {
            {},
            {''},
            {'valid', -1},
            {'valid', 1.5},
            {'valid', true},
            {valid='not an array'},
        }

        assert.equals(
            EFailureKind.INVALID_PATH, nil_result.failure.kind)
        for _, path in ipairs(cases) do
            local result = f:resolver():resolve(path)
            assert.equals(EFailureKind.INVALID_PATH, result.failure.kind)
        end
    end)

    it('rejects non-traversable declared field kinds before access',
            function()
        local f = fixture()
        local cases = {
            EFieldKind.SCALAR,
            EFieldKind.FUNCTION,
            EFieldKind.COLLECTION,
            EFieldKind.POINTER,
        }
        for index, kind in ipairs(cases) do
            f:add_field(f.main, 'field' .. index, kind, {})
        end

        for index, kind in ipairs(cases) do
            local result =
                f:resolver():resolve({'field' .. index, 'child'})
            assert.equals(
                EFailureKind.UNSUPPORTED_FIELD,
                result.failure.kind)
            assert.equals(kind, result.failure.field_kind)
        end
        assert.equals(0, #f.calls.read_field)
        assert.equals(0, #f.calls.get_widget)
    end)

    it('does not recursively search widget descendants', function()
        local f = fixture()
        local container = f:object(
            'container', {widget=true, container=true})
        local branch = f:object(
            'branch', {widget=true, container=true})
        local nested = f:object('nested', {widget=true})
        f:add_field(
            f.main, 'container', EFieldKind.WIDGET, container)
        f:add_widget(container, 'Branch', branch)
        f:add_widget(branch, 'Nested', nested)

        local result =
            f:resolver():resolve({'container', 'Nested'})

        assert.equals(EFailureKind.MISSING_WIDGET, result.failure.kind)
        assert.same({
            {parent=container, segment='Nested'},
        }, f.calls.get_widget)
    end)

    it('requires exact metadata and never indexes structural objects',
            function()
        local f = fixture()
        local child = f:object('child', {widget=true})
        local metadata = f:add_field(
            f.main, 'child', EFieldKind.WIDGET, child)

        local result = f:resolver():resolve({'child'})

        assert.is_nil(result.failure)
        assert.equals(1, #f.calls.read_field)
        assert.equals(metadata, f.calls.read_field[1].metadata)
        assert.equals(f.main, f.calls.read_field[1].parent)
    end)

    it('reports missing fields with deterministic bounded metadata',
            function()
        local f = fixture()
        for index = 1, 15 do
            f:add_field(
                f.main,
                ('field%02d'):format(index),
                EFieldKind.COMPOUND,
                f:object('value' .. index))
        end

        local result = f:resolver():resolve({'missing'})

        assert.equals(EFailureKind.MISSING_FIELD, result.failure.kind)
        assert.equals(12, #result.failure.available_fields)
        assert.equals('field01', result.failure.available_fields[1])
        assert.equals('field12', result.failure.available_fields[12])
        assert.equals(3, result.failure.omitted_field_count)
        assert.equals(0, #f.calls.read_field)
        assert.equals(0, #f.calls.get_widget)
        assert.is_true(
            #native_game_ui_path.format_failure(result) < 1024)
    end)

    it('preserves declared field order in bounded diagnostics', function()
        local f = fixture()
        for _, name in ipairs({'zeta', 'alpha', 'middle'}) do
            f:add_field(
                f.main, name, EFieldKind.COMPOUND,
                f:object('value-' .. name))
        end

        local result = f:resolver():resolve({'missing'})

        assert.same(
            {'zeta', 'alpha', 'middle'},
            result.failure.available_fields)
    end)

    it('labels traversal stages and separates both path portions',
            function()
        local f = fixture()
        local structure = f:object('structure')
        local container = f:object(
            'container', {widget=true, container=true})
        f:add_field(
            f.main, 'structure', EFieldKind.COMPOUND, structure)
        f:add_field(
            f.main, 'container', EFieldKind.WIDGET, container)

        local structural =
            f:resolver():resolve({'structure', 'missing'})
        local widget =
            f:resolver():resolve({'container', 'Missing', 'Nested'})
        local formatted = native_game_ui_path.format_failure(widget)

        assert.equals(
            EFailureKind.NON_CONTAINER_VALUE,
            structural.failure.kind)
        assert.equals(
            EResolutionStage.STRUCTURE_TRAVERSAL,
            structural.failure.stage)
        assert.equals(
            EResolutionStage.WIDGET_TRAVERSAL,
            widget.failure.stage)
        assert.matches(
            'structural_prefix={"container"}', formatted, 1, true)
        assert.matches(
            'widget_suffix={"Missing", "Nested"}', formatted, 1, true)
        assert.matches('current_type=type.container', formatted, 1, true)
    end)

    it('reports unavailable roots, types, and declared metadata',
            function()
        local f = fixture()
        f.impl.get_main_interface = function() return nil end
        local unavailable = f:resolver():resolve({'field'})
        assert.equals(
            EFailureKind.MAIN_INTERFACE_UNAVAILABLE,
            unavailable.failure.kind)
        assert.equals(
            EResolutionStage.STRUCTURE_TRAVERSAL,
            unavailable.failure.stage)

        f.impl.get_main_interface = function() return f.main end
        f.impl.get_type = function() error('type failure') end
        local no_type = f:resolver():resolve({'field'})
        assert.equals(EFailureKind.TYPE_UNAVAILABLE, no_type.failure.kind)

        f.impl.get_type = function(value) return f.types[value] end
        f.impl.get_fields = function() error('metadata failure') end
        local no_fields = f:resolver():resolve({'field'})
        assert.equals(
            EFailureKind.FIELD_METADATA_UNAVAILABLE,
            no_fields.failure.kind)
    end)

    it('reports exact field access and unsupported value failures',
            function()
        local f = fixture()
        local child = f:object('child', {widget=true})
        f:add_field(f.main, 'child', EFieldKind.WIDGET, child)
        f.impl.read_field = function() error('read failure') end

        local read_failure = f:resolver():resolve({'child'})
        assert.equals(
            EFailureKind.FIELD_ACCESS_FAILED,
            read_failure.failure.kind)

        f.impl.read_field = function() return 42 end
        local value_failure = f:resolver():resolve({'child'})
        assert.equals(
            EFailureKind.UNSUPPORTED_FIELD_VALUE,
            value_failure.failure.kind)
    end)

    it('reports missing and failed widget lookups explicitly', function()
        local f = fixture()
        local container = f:object(
            'container', {widget=true, container=true})
        f:add_field(
            f.main, 'container', EFieldKind.WIDGET, container)

        local missing =
            f:resolver():resolve({'container', 'Missing'})
        assert.equals(EFailureKind.MISSING_WIDGET, missing.failure.kind)

        f.impl.get_widget = function() error('lookup failure') end
        local failed =
            f:resolver():resolve({'container', 'Missing'})
        assert.equals(
            EFailureKind.WIDGET_LOOKUP_FAILED,
            failed.failure.kind)
    end)

    it('requires the final result to be a widget with stable identity',
            function()
        local f = fixture()
        local structure = f:object('structure')
        f:add_field(
            f.main, 'structure', EFieldKind.COMPOUND, structure)

        local not_widget = f:resolver():resolve({'structure'})
        assert.equals(
            EFailureKind.FINAL_NOT_WIDGET,
            not_widget.failure.kind)

        local widget = f:object('widget', {widget=true})
        f:add_field(f.main, 'widget', EFieldKind.WIDGET, widget)
        f.identities[widget] = nil
        local no_identity = f:resolver():resolve({'widget'})
        assert.equals(
            EFailureKind.IDENTITY_UNAVAILABLE,
            no_identity.failure.kind)
    end)

    it('accepts an exact final widget container', function()
        local f = fixture()
        local container = f:object(
            'container', {widget=true, container=true})
        f:add_field(
            f.main, 'container', EFieldKind.WIDGET, container)

        local result = f:resolver():resolve({'container'})

        assert.is_nil(result.failure)
        assert.equals(container, result.widget)
        assert.equals(container, result.widget_root)
        assert.same({'container'}, result.structural_segments)
        assert.same({}, result.widget_segments)
    end)

    it('never invokes mutation callbacks while resolving failures',
            function()
        local f = fixture()
        local callbacks = {
            on_input=function()
                f.mutation_count = f.mutation_count + 1
            end,
            on_render=function()
                f.mutation_count = f.mutation_count + 1
            end,
            on_activate=function()
                f.mutation_count = f.mutation_count + 1
            end,
        }
        local callback_object = f:object('callbacks')
        f:add_field(
            f.main,
            'callbacks',
            EFieldKind.FUNCTION,
            callbacks)
        f.values[callback_object] = callbacks

        local result =
            f:resolver():resolve({'callbacks', 'on_input'})

        assert.equals(
            EFailureKind.UNSUPPORTED_FIELD,
            result.failure.kind)
        assert.equals(0, f.mutation_count)
    end)

    it('never enumerates structural objects or undeclared object fields',
            function()
        local f = fixture()
        local declared = f:object('declared')
        f:add_field(
            f.main, 'declared', EFieldKind.COMPOUND, declared)

        local result = f:resolver():resolve({'undeclared'})

        assert.equals(EFailureKind.MISSING_FIELD, result.failure.kind)
        assert.same({'declared'}, result.failure.available_fields)
        assert.equals(1, #f.calls.get_fields)
        assert.equals(0, #f.calls.read_field)
        assert.equals(0, #f.calls.get_widget)
    end)

    it('bounds injected error labels in failure records', function()
        local f = fixture()
        f.impl.get_type = function()
            error(string.rep('x', 200))
        end

        local result = f:resolver():resolve({'field'})

        assert.equals(EFailureKind.TYPE_UNAVAILABLE, result.failure.kind)
        assert.is_true(#result.failure.detail <= 80)
        assert.equals('...', result.failure.detail:sub(-3))
    end)

    it('checks only the exact declared leading field without reading it',
            function()
        local f = fixture()
        local info = f:object('info')
        f:add_field(f.main, 'info', EFieldKind.COMPOUND, info)
        local resolver = f:resolver()

        assert.is_true(
            resolver:has_declared_leading_field({'info', 'Tabs'}))
        assert.is_false(
            resolver:has_declared_leading_field({'missing', 'Tabs'}))
        assert.is_false(resolver:has_declared_leading_field({0}))
        assert.equals(0, #f.calls.read_field)
        assert.equals(0, #f.calls.get_widget)
    end)

    it('creates a structural root locator that replays from main_interface',
            function()
        local f = fixture()
        local first = f:object(
            'stable-root', {widget=true, container=true})
        local metadata = f:add_field(
            f.main, 'info', EFieldKind.WIDGET, first)
        local resolver = f:resolver()
        local locate = resolver:root_locator({'info'})

        assert.equals(first, locate())

        local second = f:object(
            'stable-root', {
                widget=true,
                container=true,
                identity='stable-root',
            })
        f.values[f.main][metadata] = second
        assert.equals(second, locate())
        assert.is_not.equal(first, second)
    end)

    it('adapts documented DF field metadata for the common game-UI path',
            function()
        local dead = {
            id='dead',
            _type={_fields={}},
            widget=true,
            container=true,
            children={},
        }
        local tabs = {
            id='tabs',
            name='Tabs',
            _type={_fields={}},
            widget=true,
            container=true,
            children={dead},
        }
        dead.name = 'Dead/Missing'
        local creatures = {
            id='creatures',
            _type={_fields={
                scalar={name='scalar', mode=EFieldMode.PRIMITIVE},
            }},
            widget=true,
            container=true,
            children={tabs},
            scalar=42,
        }
        local info = {
            _type={_fields={
                creatures={name='creatures', mode=EFieldMode.SUBSTRUCT},
            }},
            creatures=creatures,
        }
        local main_interface = {
            _type={_fields={
                info={name='info', mode=EFieldMode.SUBSTRUCT},
            }},
            info=info,
        }
        local df_namespace = {
            global={game={main_interface=main_interface}},
            widget={
                is_instance=function(_, value)
                    return value and value.widget == true
                end,
            },
            widget_container={
                is_instance=function(_, value)
                    return value and value.container == true
                end,
            },
        }
        local resolver = native_game_ui_path.new_dfhack({
            df=df_namespace,
            get_widget=function(parent, segment)
                for _, child in ipairs(parent.children or {}) do
                    if child.name == segment then return child end
                end
                return nil
            end,
            identity_of=function(value) return value.id or value end,
        })

        local result = resolver:resolve({
            'info',
            'creatures',
            'Tabs',
            'Dead/Missing',
        })
        local scalar = resolver:resolve({
            'info',
            'creatures',
            'scalar',
        })

        assert.is_nil(result.failure)
        assert.same({'info', 'creatures'}, result.structural_segments)
        assert.same({'Tabs', 'Dead/Missing'}, result.widget_segments)
        assert.equals(dead, result.widget)
        assert.equals(EFailureKind.UNSUPPORTED_FIELD, scalar.failure.kind)
        assert.equals(EFieldKind.SCALAR, scalar.failure.field_kind)
    end)

    it('formats every failure kind within deterministic bounds', function()
        local cases = {}

        ---Adds one failed resolution to the bounded-format matrix.
        ---@param expected DwarfSpecENativeResolutionFailureKind
        ---@param result dwarfspec.GameUIPathResolution
        local function add(expected, result)
            table.insert(cases, {expected=expected, result=result})
        end

        local invalid = fixture()
        add(EFailureKind.INVALID_PATH, invalid:resolver():resolve(nil))

        local unavailable = fixture()
        unavailable.impl.get_main_interface = function() return nil end
        add(EFailureKind.MAIN_INTERFACE_UNAVAILABLE,
            unavailable:resolver():resolve({'field'}))

        local no_type = fixture()
        no_type.impl.get_type = function() error(string.rep('t', 512)) end
        add(EFailureKind.TYPE_UNAVAILABLE,
            no_type:resolver():resolve({'field'}))

        local no_metadata = fixture()
        no_metadata.impl.get_fields =
            function() error(string.rep('m', 512)) end
        add(EFailureKind.FIELD_METADATA_UNAVAILABLE,
            no_metadata:resolver():resolve({'field'}))

        local invalid_segment = fixture()
        add(EFailureKind.INVALID_STRUCTURAL_SEGMENT,
            invalid_segment:resolver():resolve({0}))

        local missing = fixture()
        add(EFailureKind.MISSING_FIELD,
            missing:resolver():resolve({'missing'}))

        local non_container = fixture()
        local structure = non_container:object('structure')
        non_container:add_field(
            non_container.main, 'structure',
            EFieldKind.COMPOUND, structure)
        add(EFailureKind.NON_CONTAINER_VALUE,
            non_container:resolver():resolve({'structure', 'missing'}))

        local unsupported = fixture()
        unsupported:add_field(
            unsupported.main, 'scalar', EFieldKind.SCALAR, 42)
        add(EFailureKind.UNSUPPORTED_FIELD,
            unsupported:resolver():resolve({'scalar'}))

        local read_failed = fixture()
        local read_child = read_failed:object(
            'read-child', {widget=true})
        read_failed:add_field(
            read_failed.main, 'child',
            EFieldKind.WIDGET, read_child)
        read_failed.impl.read_field =
            function() error(string.rep('r', 512)) end
        add(EFailureKind.FIELD_ACCESS_FAILED,
            read_failed:resolver():resolve({'child'}))

        local invalid_value = fixture()
        local invalid_child = invalid_value:object(
            'invalid-child', {widget=true})
        invalid_value:add_field(
            invalid_value.main, 'child',
            EFieldKind.WIDGET, invalid_child)
        invalid_value.impl.read_field = function() return 42 end
        add(EFailureKind.UNSUPPORTED_FIELD_VALUE,
            invalid_value:resolver():resolve({'child'}))

        local lookup_failed = fixture()
        local lookup_container = lookup_failed:object(
            'container', {widget=true, container=true})
        lookup_failed:add_field(
            lookup_failed.main, 'container',
            EFieldKind.WIDGET, lookup_container)
        lookup_failed.impl.get_widget =
            function() error(string.rep('w', 512)) end
        add(EFailureKind.WIDGET_LOOKUP_FAILED,
            lookup_failed:resolver():resolve({'container', 'Missing'}))

        local widget_missing = fixture()
        local missing_container = widget_missing:object(
            'container', {widget=true, container=true})
        widget_missing:add_field(
            widget_missing.main, 'container',
            EFieldKind.WIDGET, missing_container)
        add(EFailureKind.MISSING_WIDGET,
            widget_missing:resolver():resolve({'container', 'Missing'}))

        local final_invalid = fixture()
        local final_structure = final_invalid:object('structure')
        final_invalid:add_field(
            final_invalid.main, 'structure',
            EFieldKind.COMPOUND, final_structure)
        add(EFailureKind.FINAL_NOT_WIDGET,
            final_invalid:resolver():resolve({'structure'}))

        local identity_missing = fixture()
        local identity_widget = identity_missing:object(
            'widget', {widget=true})
        identity_missing:add_field(
            identity_missing.main, 'widget',
            EFieldKind.WIDGET, identity_widget)
        identity_missing.identities[identity_widget] = nil
        add(EFailureKind.IDENTITY_UNAVAILABLE,
            identity_missing:resolver():resolve({'widget'}))

        local observed = {}
        for _, case in ipairs(cases) do
            local result = case.result
            local formatted =
                native_game_ui_path.format_failure(result)
            assert.equals(case.expected, result.failure.kind)
            assert.is_not_nil(result.failure.stage)
            assert.matches(
                'kind=' .. case.expected, formatted, 1, true)
            assert.is_true(#formatted < 4096)
            observed[case.expected] = true
        end
        for _, kind in pairs(EFailureKind) do
            assert.is_true(
                observed[kind],
                'missing bounded diagnostic case for ' .. kind)
        end
    end)
end)
