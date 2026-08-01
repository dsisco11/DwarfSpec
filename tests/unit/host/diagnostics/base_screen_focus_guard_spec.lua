-- Unit contracts for detached base-game screen and focus observations.

local guard_module =
    require('dwarfspec.host.diagnostics.base_screen_focus_guard')
local EComparison =
    require('dwarfspec.protocol.diagnostics.base_screen_focus_comparisons')
local events = require('dwarfspec.protocol.events')

---Returns one fake screen with a stable diagnostic class name.
---@param name string
---@return table
local function screen(name)
    return {_type={_name=name}}
end

---Returns injected GUI behavior over mutable test state.
---@param state table
---@return table
local function gui(state)
    return {
        getDFViewscreen=function(skip_dismissed)
            assert.is_true(skip_dismissed)
            if state.screen_error then error(state.screen_error, 0) end
            return state.screen
        end,
        getFocusStrings=function(target)
            assert.equals(state.screen, target)
            if state.focus_error then error(state.focus_error, 0) end
            return state.focus
        end,
    }
end

---Asserts that a value tree contains only detached JSON-safe data.
---@param value any
---@param active table|nil
local function assert_detached(value, active)
    local value_type = type(value)
    assert.is_not.equals('userdata', value_type)
    assert.is_not.equals('function', value_type)
    assert.is_not.equals('thread', value_type)
    if value_type ~= 'table' then return end
    active = active or {}
    assert.is_nil(active[value], 'diagnostic contains a cycle')
    active[value] = true
    for key, child in pairs(value) do
        assert_detached(key, active)
        assert_detached(child, active)
    end
    active[value] = nil
end

describe('base-screen focus guard', function()
    it('emits nothing for identical present screen and focus state',
            function()
        local current = screen('df.viewscreen_dwarfmodest')
        local state = {screen=current, focus={'dwarfmode/Default'}}
        local guard = guard_module.new(gui(state))

        local before = guard:capture()
        local after = guard:capture()

        assert.is_nil(guard:compare(before, after))
    end)

    it('treats equivalent userdata-style wrappers as one screen identity',
            function()
        local wrapper = {
            __eq=function(left, right)
                return left.identity == right.identity
            end,
        }
        local state = {
            screen=setmetatable({
                identity='same native screen',
                _type={_name='df.viewscreen_dwarfmodest'},
            }, wrapper),
            focus={'dwarfmode/Default'},
        }
        local guard = guard_module.new(gui(state))
        local before = guard:capture()
        state.screen = setmetatable({
            identity='same native screen',
            _type={_name='df.viewscreen_dwarfmodest'},
        }, wrapper)
        local after = guard:capture()

        assert.is_nil(guard:compare(before, after))
    end)

    it('detects a different screen instance with identical details',
            function()
        local state = {
            screen=screen('df.viewscreen_layerst'),
            focus={'layer/Default'},
        }
        local guard = guard_module.new(gui(state))
        local before = guard:capture()
        state.screen = screen('df.viewscreen_layerst')
        local after = guard:capture()

        local diagnostic = assert(guard:compare(before, after))
        assert.equals('base_screen_focus_changed', diagnostic.kind)
        assert.equals('warning', diagnostic.content.severity)
        assert.equals(
            EComparison.CHANGED, diagnostic.content.screen_comparison)
        assert.equals(EComparison.SAME, diagnostic.content.focus_comparison)
        assert.is_true(diagnostic.content.details_complete)
    end)

    it('treats two successful absent screens as unchanged', function()
        local state = {screen=nil}
        local guard = guard_module.new(gui(state))

        local before = guard:capture()
        local after = guard:capture()

        assert.equals('none', before.details.screen.status)
        assert.equals('available', before.details.focus.status)
        assert.same({}, before.details.focus.values)
        assert.is_nil(guard:compare(before, after))
    end)

    it('detects transitions between absent and present screens', function()
        for _, scenario in ipairs({
                {before=nil, after=screen('df.viewscreen_dwarfmodest')},
                {before=screen('df.viewscreen_dwarfmodest'), after=nil},
            }) do
            local state = {screen=scenario.before, focus={}}
            local guard = guard_module.new(gui(state))
            local before = guard:capture()
            state.screen = scenario.after
            local after = guard:capture()

            local diagnostic = assert(guard:compare(before, after))
            assert.equals(EComparison.CHANGED,
                diagnostic.content.screen_comparison)
            assert.equals(
                EComparison.SAME, diagnostic.content.focus_comparison)
            assert.is_true(diagnostic.content.details_complete)
        end
    end)

    it('distinguishes capture failure from an absent screen', function()
        local state = {
            screen_error='screen capture failed',
            focus={},
        }
        local guard = guard_module.new(gui(state))
        local before = guard:capture()
        state.screen_error = nil
        state.screen = nil
        local after = guard:capture()

        local diagnostic = assert(guard:compare(before, after))
        assert.equals('base_screen_focus_verification_incomplete',
            diagnostic.kind)
        assert.equals('info', diagnostic.content.severity)
        assert.equals(EComparison.UNAVAILABLE,
            diagnostic.content.screen_comparison)
        assert.equals(EComparison.UNAVAILABLE,
            diagnostic.content.focus_comparison)
        assert.is_false(diagnostic.content.details_complete)
        assert.equals('unavailable', before.details.screen.status)
        assert.equals('none', after.details.screen.status)
    end)

    it('detects changed focus membership on the same screen', function()
        local current = screen('df.viewscreen_dwarfmodest')
        local state = {screen=current, focus={'dwarfmode/Default'}}
        local guard = guard_module.new(gui(state))
        local before = guard:capture()
        state.focus = {'dwarfmode/Info/CREATURES'}
        local after = guard:capture()

        local diagnostic = assert(guard:compare(before, after))
        assert.equals(
            EComparison.SAME, diagnostic.content.screen_comparison)
        assert.equals(
            EComparison.CHANGED, diagnostic.content.focus_comparison)
    end)

    it('ignores focus ordering and duplicate strings', function()
        local current = screen('df.viewscreen_dwarfmodest')
        local state = {
            screen=current,
            focus={'dwarfmode/Squads', 'dwarfmode/Default',
                'dwarfmode/Squads'},
        }
        local guard = guard_module.new(gui(state))
        local before = guard:capture()
        state.focus = {'dwarfmode/Default', 'dwarfmode/Squads'}
        local after = guard:capture()

        assert.is_nil(guard:compare(before, after))
    end)

    it('preserves screen changes when focus capture is unavailable',
            function()
        local state = {
            screen=screen('df.viewscreen_layerst'),
            focus={'layer/Default'},
        }
        local guard = guard_module.new(gui(state))
        local before = guard:capture()
        state.screen = screen('df.viewscreen_layerst')
        state.focus_error = 'focus failed'
        local after = guard:capture()

        local diagnostic = assert(guard:compare(before, after))
        assert.equals('base_screen_focus_changed', diagnostic.kind)
        assert.equals(
            EComparison.CHANGED, diagnostic.content.screen_comparison)
        assert.equals(EComparison.UNAVAILABLE,
            diagnostic.content.focus_comparison)
        assert.is_false(diagnostic.content.details_complete)
        assert.equals('focus failed',
            diagnostic.content.after.focus.error)
    end)

    it('preserves focus changes when screen evidence is unavailable',
            function()
        local current = screen('df.viewscreen_dwarfmodest')
        local state = {screen=current, focus={'dwarfmode/Default'}}
        local guard = guard_module.new(gui(state))
        local before = guard:capture()
        state.focus = {'dwarfmode/Squads'}
        local after = guard:capture()
        before.private.screen.status = 'unavailable'
        before.details.screen = {
            status='unavailable',
            error='screen identity unavailable',
        }

        local diagnostic = assert(guard:compare(before, after))
        assert.equals('base_screen_focus_changed', diagnostic.kind)
        assert.equals(EComparison.UNAVAILABLE,
            diagnostic.content.screen_comparison)
        assert.equals(
            EComparison.CHANGED, diagnostic.content.focus_comparison)
        assert.is_false(diagnostic.content.details_complete)
        assert.equals('unavailable',
            diagnostic.content.before.screen.status)
        assert.equals('screen identity unavailable',
            diagnostic.content.before.screen.error)
    end)

    it('emits incomplete verification when no change is known',
            function()
        local state = {
            screen_error='screen unavailable',
            focus={},
        }
        local guard = guard_module.new(gui(state))

        local diagnostic = assert(guard:compare(
            guard:capture(), guard:capture()))

        assert.equals('base_screen_focus_verification_incomplete',
            diagnostic.kind)
        assert.equals('info', diagnostic.content.severity)
        assert.equals(EComparison.UNAVAILABLE,
            diagnostic.content.screen_comparison)
        assert.equals(EComparison.UNAVAILABLE,
            diagnostic.content.focus_comparison)
        assert.is_false(diagnostic.content.details_complete)
    end)

    it('detaches diagnostics from mutable DFHack-owned focus tables',
            function()
        local current = screen('df.viewscreen_dwarfmodest')
        local source = {'dwarfmode/Default'}
        local state = {screen=current, focus=source}
        local guard = guard_module.new(gui(state))
        local before = guard:capture()
        source[1] = 'mutated/after/capture'
        state.focus = {'dwarfmode/Squads'}
        local after = guard:capture()

        local diagnostic = assert(guard:compare(before, after))
        assert.equals('dwarfmode/Default',
            diagnostic.content.before.focus.values[1])
        assert_detached(diagnostic)
        assert.same(diagnostic,
            events.copy_json(diagnostic, 'focus diagnostic'))
        assert.is_nil(tostring(diagnostic.content.before.screen.type)
            :match('0[xX][0-9a-fA-F]+'))
    end)

    it('bounds errors, focus counts, strings, and screen labels',
            function()
        local state = {
            screen=screen('screen-label-0x123456789-extra'),
            focus={'focus-value-that-is-too-long', 'second'},
        }
        local guard = guard_module.new(gui(state), {
            max_error_bytes=12,
            max_focus_count=1,
            max_focus_string_bytes=10,
            max_screen_label_bytes=16,
        })
        local observation = guard:capture()

        assert.is_true(#observation.details.screen.type <= 16)
        assert.is_nil(observation.details.screen.type
            :match('0[xX][0-9a-fA-F]+'))
        assert.equals('unavailable', observation.details.focus.status)
        assert.is_true(observation.details.focus.truncated)
        assert.is_true(#observation.details.focus.values <= 1)
        assert.is_true(#observation.details.focus.values[1] <= 10)
        assert.is_true(#observation.details.focus.error <= 12)

        state.focus = {'short', 'second'}
        local count_limited = guard:capture()
        assert.equals('unavailable', count_limited.details.focus.status)
        assert.is_true(count_limited.details.focus.truncated)
        assert.equals(1, #count_limited.details.focus.values)

        state.focus = nil
        state.focus_error = string.rep('failure-', 10)
        local failed = guard:capture()
        assert.is_true(#failed.details.focus.error <= 12)

        state.screen_error = string.rep('screen-failure-', 10)
        local screen_failed = guard:capture()
        assert.is_true(#screen_failed.details.screen.error <= 12)
    end)
end)
