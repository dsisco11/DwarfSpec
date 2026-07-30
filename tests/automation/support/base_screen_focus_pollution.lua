-- Shared assertions for ordered live base-screen focus-pollution fixtures.

local gui = require('gui')

local M = {
    CHANGE_KIND='base_screen_focus_changed',
    DIAGNOSTIC_EVENT='diagnostic.recorded',
    TEST_FINISHED_EVENT='test.finished',
    EXAMPLE_SUITE=
        'tests/automation/base_screen_focus_pollution/' ..
        '01_example_live_spec.lua',
    PRODUCER_SUITE=
        'tests/automation/base_screen_focus_pollution/' ..
        '02_suite_producer_live_spec.lua',
    RESTORER_SUITE=
        'tests/automation/base_screen_focus_pollution/' ..
        '03_suite_observer_restore_live_spec.lua',
    ds=nil,
    expect=nil,
}

---Binds the file-local DwarfSpec API exported by the automation host.
---@param api table
---@param assertions table
function M.bind(api, assertions)
    assert(type(api) == 'table',
        'focus fixture requires the exported DwarfSpec API')
    assert(type(assertions) == 'table',
        'focus fixture requires the exported assertion API')
    M.ds = api
    M.expect = assertions
end

---Returns the explicitly bound DwarfSpec API.
---@return table
local function bound_ds()
    return assert(M.ds, 'focus fixture DwarfSpec API was not bound')
end

---Returns a detached copy of one dense array.
---@param values any[]
---@return any[]
function M.copy_array(values)
    local copy = {}
    for index, value in ipairs(values) do copy[index] = value end
    return copy
end

---Returns the active run-owned state shared by the ordered fixture files.
---@return table
function M.state()
    local run = bound_ds().current_run()
    run.base_screen_focus_pollution_live =
        run.base_screen_focus_pollution_live or {}
    return run.base_screen_focus_pollution_live
end

---Captures the exact original base-screen identity and focus once.
---@return table
function M.capture_original()
    local state = M.state()
    M.expect.is_nil(state.original_screen,
        'ordered focus fixture baseline was already captured')
    local screen = dfhack.gui.getDFViewscreen(true)
    M.expect.is_not_nil(screen, 'focus fixture requires a base-game screen')
    M.expect.is_true(dfhack.world.isFortressMode(),
        'focus fixture requires a loaded fortress')
    M.expect.is_true(dfhack.gui.matchFocusString(
        'dwarfmode/Default', screen),
        'focus fixture must start at dwarfmode/Default')
    state.original_screen = screen
    state.original_focus =
        M.copy_array(dfhack.gui.getFocusStrings(screen))
    return state
end

---Returns the current immutable automation event sequence.
---@return table[]
function M.events()
    return bound_ds().current_run().event_journal.events
end

---Returns focus-change diagnostic events matching an optional predicate.
---@param predicate fun(content: table, event: table): boolean|nil
---@return table[]
function M.change_events(predicate)
    local matches = {}
    for _, event in ipairs(M.events()) do
        local payload = event.payload
        if event.type == M.DIAGNOSTIC_EVENT and
                payload.kind == M.CHANGE_KIND and
                (predicate == nil or predicate(payload.content, event)) then
            table.insert(matches, event)
        end
    end
    return matches
end

---Finds one successful test result by its complete Busted example name.
---@param example_name string
---@return table
function M.success_event(example_name)
    for _, event in ipairs(M.events()) do
        if event.type == M.TEST_FINISHED_EVENT and
                event.payload.name == example_name and
                event.payload.status == 'success' then
            return event
        end
    end
    error('successful test event was not found: ' .. example_name, 2)
end

---Asserts one exact, complete focus-only change diagnostic.
---@param event table
---@param expected table
function M.assert_focus_change(event, expected)
    local content = event.payload.content
    M.expect.equals(M.CHANGE_KIND, event.payload.kind)
    M.expect.equals('warning', content.severity)
    M.expect.equals(expected.scope, content.scope)
    M.expect.equals(expected.attribution, content.attribution)
    M.expect.equals(expected.suite_name, content.suite_name)
    M.expect.equals(expected.example_name, content.example_name)
    M.expect.equals(expected.suite_name, content.source_identity)
    M.expect.equals(1, content.repeat_index)
    M.expect.equals(1, content.screen_comparison)
    M.expect.equals(2, content.focus_comparison)
    M.expect.is_true(content.details_complete)
    M.expect.equals('present', content.before.screen.status)
    M.expect.equals('present', content.after.screen.status)
    M.expect.equals(content.before.screen.type, content.after.screen.type)
    M.expect.equals('available', content.before.focus.status)
    M.expect.equals('available', content.after.focus.status)
    M.expect.is_not.same(
        content.before.focus.values, content.after.focus.values)
end

---Opens the reversible native Hauling focus on the original base screen.
function M.open_hauling()
    local state = M.state()
    local screen = assert(state.original_screen,
        'focus fixture baseline was not captured')
    M.expect.equals(screen, dfhack.gui.getDFViewscreen(true),
        'base-screen identity changed before opening Hauling')
    M.expect.is_true(dfhack.gui.matchFocusString(
        'dwarfmode/Default', screen))
    gui.simulateInput(screen, 'D_HAULING')
    bound_ds().await('focus fixture opens Hauling', function()
        return dfhack.gui.matchFocusString('dwarfmode/Hauling', screen)
    end)
    M.expect.equals(screen, dfhack.gui.getDFViewscreen(true),
        'opening Hauling replaced the original base screen')
end

---Restores and proves the exact original base-screen identity and focus.
function M.restore_original()
    local state = M.state()
    local screen = assert(state.original_screen,
        'focus fixture baseline was not captured')
    M.expect.equals(screen, dfhack.gui.getDFViewscreen(true),
        'base-screen identity changed before fixture restoration')
    if not dfhack.gui.matchFocusString('dwarfmode/Default', screen) then
        gui.simulateInput(screen, 'LEAVESCREEN')
        bound_ds().await('focus fixture restores original focus', function()
            return dfhack.gui.matchFocusString(
                'dwarfmode/Default', screen)
        end)
    end
    M.expect.equals(screen, dfhack.gui.getDFViewscreen(true),
        'fixture restoration replaced the original base screen')
    M.expect.same(state.original_focus, dfhack.gui.getFocusStrings(screen))
end

---Discards the fixture-only run state after final restoration is proven.
function M.clear_state()
    local run = bound_ds().current_run()
    run.base_screen_focus_pollution_live = nil
end

return M
