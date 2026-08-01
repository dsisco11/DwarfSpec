-- Unit contracts for read-only DFHack overlay-registry subject adaptation.

local ESubjectSource = require('dwarfspec.driver.subjects.subject_sources')
local overlay_registry_adapter =
    require('dwarfspec.driver.subjects.overlay_registry_adapter')

---Creates one minimal Lua view with ordered children.
---@param view_id string
---@param children table[]|nil
---@param fields table|nil
---@return table
local function view(view_id, children, fields)
    local result = {
        view_id=view_id,
        subviews=children or {},
        visible=true,
        active=true,
    }
    for name, value in pairs(fields or {}) do result[name] = value end
    return result
end

describe('DwarfSpec overlay registry adapter', function()
    local state
    local root
    local child
    local get_state_calls

    before_each(function()
        child = view('child', nil, {
            text='overlay child',
            frame_body={x1=1, y1=2, x2=3, y2=4},
        })
        root = view('overlay-root', {child})
        state = {
            db={
                ['gui/example.ExampleOverlay']={widget=root},
            },
            config={
                ['gui/example.ExampleOverlay']={enabled=true},
            },
            index={'gui/example.ExampleOverlay'},
        }
        get_state_calls = 0
    end)

    ---Returns the current injected registry state.
    ---@return table
    local function get_state()
        get_state_calls = get_state_calls + 1
        return state
    end

    it('pins the exact enabled registry name and delegates Lua-view behavior',
            function()
        local source = overlay_registry_adapter.new_source(
            'gui/example.ExampleOverlay', {get_state=get_state})
        local adapter = source.adapter

        assert.equals(ESubjectSource.OVERLAY, source.kind)
        assert.equals('gui/example.ExampleOverlay', source.overlay)
        assert.equals(root, adapter:root())
        assert.equals(child, adapter:resolve({'child'}))
        assert.equals(child, adapter:identity(child))
        assert.is_true(adapter:contains(child))
        assert.same({child}, adapter:children(root))
        assert.same({
            class='table',
            view_id='child',
            visible=true,
            active=true,
            focused=false,
            frame=nil,
            body={x1=1, y1=2, x2=3, y2=4},
            text='overlay child',
            tooltip=nil,
        }, adapter:inspect(child))
        assert.is_true(adapter:is_current())
        assert.is_true(get_state_calls >= 8)
    end)

    it('rejects missing, disabled, and invalid exact registry entries',
            function()
        assert.has_error(function()
            overlay_registry_adapter.new(
                'gui/example.Missing', {get_state=get_state})
        end, 'DwarfSpec overlay subject selection could not find exact ' ..
            'registry name="gui/example.Missing"')

        state.config['gui/example.ExampleOverlay'].enabled = false
        assert.has_error(function()
            overlay_registry_adapter.new(
                'gui/example.ExampleOverlay', {get_state=get_state})
        end, 'DwarfSpec overlay subject selection requires enabled ' ..
            'registry name="gui/example.ExampleOverlay"')

        state.config['gui/example.ExampleOverlay'].enabled = true
        state.db['gui/example.ExampleOverlay'].widget = {not_a_view=true}
        assert.has_error(function()
            overlay_registry_adapter.new(
                'gui/example.ExampleOverlay', {get_state=get_state})
        end, 'DwarfSpec overlay subject selection requires registry ' ..
            'name="gui/example.ExampleOverlay" to contain a valid Lua view')
    end)

    it('makes existing subjects stale after removal or disablement', function()
        local removed = overlay_registry_adapter.new(
            'gui/example.ExampleOverlay', {get_state=get_state})
        state.db['gui/example.ExampleOverlay'] = nil
        assert.has_error(function() removed:root() end,
            'DwarfSpec stale overlay subject could not find exact registry ' ..
                'name="gui/example.ExampleOverlay"')

        state.db['gui/example.ExampleOverlay'] = {widget=root}
        local disabled = overlay_registry_adapter.new(
            'gui/example.ExampleOverlay', {get_state=get_state})
        state.config['gui/example.ExampleOverlay'].enabled = false
        assert.has_error(function() disabled:inspect(root) end,
            'DwarfSpec stale overlay subject requires enabled registry ' ..
                'name="gui/example.ExampleOverlay"')
    end)

    it('does not bind a stale adapter to a same-name rescan replacement',
            function()
        local original = overlay_registry_adapter.new(
            'gui/example.ExampleOverlay', {get_state=get_state})
        local replacement = view('overlay-root')
        state.db['gui/example.ExampleOverlay'] = {widget=replacement}

        assert.has_error(function() original:root() end,
            'DwarfSpec stale overlay subject registry ' ..
                'name="gui/example.ExampleOverlay" was replaced; select ' ..
                'the overlay source again')
        local selected_again = overlay_registry_adapter.new(
            'gui/example.ExampleOverlay', {get_state=get_state})
        assert.equals(replacement, selected_again:root())
    end)

    it('never mutates registry state or invokes overlay lifecycle callbacks',
            function()
        local lifecycle_calls = 0
        root.overlay_onenable = function()
            lifecycle_calls = lifecycle_calls + 1
        end
        root.overlay_ondisable = function()
            lifecycle_calls = lifecycle_calls + 1
        end
        root.updateFrames = function()
            lifecycle_calls = lifecycle_calls + 1
        end
        local original_entry = state.db['gui/example.ExampleOverlay']
        local original_config = state.config['gui/example.ExampleOverlay']
        local adapter = overlay_registry_adapter.new(
            'gui/example.ExampleOverlay', {get_state=get_state})

        adapter:inspect(root)
        assert.is_true(adapter:cleanup())
        assert.is_false(adapter:cleanup())
        assert.equals(0, lifecycle_calls)
        assert.equals(original_entry,
            state.db['gui/example.ExampleOverlay'])
        assert.equals(original_config,
            state.config['gui/example.ExampleOverlay'])
        assert.is_true(state.config['gui/example.ExampleOverlay'].enabled)
    end)
end)
