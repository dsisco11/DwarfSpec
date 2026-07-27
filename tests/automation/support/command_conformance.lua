-- Shared assertions and fixture ownership for mount-command live conformance.

local M = {}

local BOOLEAN_CAPABILITIES = {
    root_inspection=true,
    tree_capture=true,
    screen_capture=true,
    subject_pointer_placement=true,
    subject_hover=true,
    keyboard_input=true,
    text_input=true,
    physical_mouse_states=true,
    default_wait_redraw=true,
    no_wait_redraw=true,
}

local POINTER_BUTTON_FIELDS = {
    'mouse_focus',
    'tracking_on',
    'mouse_lbut_down',
    'mouse_lbut_lift',
    'mouse_rbut_down',
    'mouse_rbut_lift',
    'mouse_mbut_down',
    'mouse_mbut_lift',
}

---Returns a shallow copy that cannot mutate the caller's capability table.
---@param source table
---@return table
local function copy_table(source)
    local result = {}
    for name, value in pairs(source) do result[name] = value end
    return result
end

---Formats one value for deterministic validation diagnostics.
---@param value any
---@return string
local function display(value)
    if type(value) == 'string' then return ('%q'):format(value) end
    return tostring(value)
end

---Validates one complete mount-host capability declaration.
---@param capabilities table
---@return table
local function validate_capabilities(capabilities)
    assert(type(capabilities) == 'table',
        'command conformance capabilities must be a table')
    for name in pairs(capabilities) do
        assert(BOOLEAN_CAPABILITIES[name] or name == 'viewport',
            'unknown command conformance capability: ' .. tostring(name))
    end
    for name in pairs(BOOLEAN_CAPABILITIES) do
        assert(type(capabilities[name]) == 'boolean',
            ('command conformance capability %s must be boolean; got %s')
                :format(name, display(capabilities[name])))
    end
    assert(capabilities.viewport == 'supported' or
        capabilities.viewport == 'rejected',
        'command conformance capability viewport must be "supported" or ' ..
        ('"rejected"; got %s'):format(display(capabilities.viewport)))
    assert(not capabilities.subject_hover or
        capabilities.subject_pointer_placement,
        'subject_hover requires subject_pointer_placement')
    assert(not capabilities.physical_mouse_states or
        capabilities.subject_pointer_placement,
        'physical_mouse_states requires subject_pointer_placement')
    assert(not capabilities.text_input or capabilities.keyboard_input,
        'text_input requires keyboard_input')
    assert(not capabilities.no_wait_redraw or
        capabilities.default_wait_redraw,
        'no_wait_redraw requires default_wait_redraw')
    return copy_table(capabilities)
end

---Compares two flat snapshots and raises with the differing field name.
---@param expected table
---@param actual table
---@param description string
local function assert_flat_equal(expected, actual, description)
    for name, value in pairs(expected) do
        assert(actual[name] == value,
            ('%s field %s changed: expected %s, got %s'):format(
                description, tostring(name), display(value),
                display(actual[name])))
    end
    for name in pairs(actual) do
        assert(expected[name] ~= nil,
            ('%s gained unexpected field %s'):format(
                description, tostring(name)))
    end
end

---Creates shared conformance assertions for one mount-specific fixture.
---@param capabilities table
---@return table
function M.new(capabilities)
    local helper = {
        capabilities=validate_capabilities(capabilities),
        cleanup_actions={},
        counters={},
        running=false,
    }

    ---Registers one fixture-owned cleanup action.
    ---@param name string
    ---@param action function
    function helper:defer(name, action)
        assert(type(name) == 'string' and name ~= '',
            'conformance cleanup name must be a nonempty string')
        assert(type(action) == 'function',
            'conformance cleanup action must be a function')
        table.insert(self.cleanup_actions, {name=name, action=action})
    end

    ---Runs and removes all fixture cleanup actions in reverse order.
    ---@return boolean, table[]
    function helper:cleanup()
        local failures = {}
        while #self.cleanup_actions > 0 do
            local entry = table.remove(self.cleanup_actions)
            local ok, failure = xpcall(entry.action, debug.traceback)
            if not ok then
                table.insert(failures, {
                    name=entry.name,
                    message=tostring(failure),
                })
            end
        end
        return #failures == 0, failures
    end

    ---Executes a fixture body and always runs its owned cleanup.
    ---@param body function
    ---@return any
    function helper:run(body)
        assert(type(body) == 'function',
            'conformance fixture body must be a function')
        assert(not self.running,
            'command conformance fixture cannot run recursively')
        self.running = true
        local result
        local body_ok, body_failure = xpcall(function()
            result = body(self)
        end, debug.traceback)
        local cleanup_ok, cleanup_failures = self:cleanup()
        self.running = false
        if not body_ok then
            if not cleanup_ok then
                error(('%s; cleanup also failed: %s: %s'):format(
                    tostring(body_failure), cleanup_failures[1].name,
                    cleanup_failures[1].message), 0)
            end
            error(body_failure, 0)
        end
        if not cleanup_ok then
            error(('command conformance cleanup failed: %s: %s'):format(
                cleanup_failures[1].name,
                cleanup_failures[1].message), 0)
        end
        return result
    end

    ---Asserts that no fixture-owned cleanup action remains pending.
    function helper:assert_clean()
        assert(#self.cleanup_actions == 0,
            ('command conformance fixture retains %d cleanup action(s)')
                :format(#self.cleanup_actions))
    end

    ---Returns an increment callback and reader for one observation counter.
    ---@param name string
    ---@return function, function
    function helper:counter(name)
        assert(type(name) == 'string' and name ~= '',
            'observation counter name must be a nonempty string')
        assert(self.counters[name] == nil,
            'duplicate observation counter: ' .. name)
        self.counters[name] = 0

        ---Records one observation reached by the fixture's normal dispatch.
        ---@param amount integer|nil
        local function observe(amount)
            amount = amount or 1
            assert(type(amount) == 'number' and amount > 0 and
                amount % 1 == 0,
                'observation increment must be a positive integer')
            helper.counters[name] = helper.counters[name] + amount
            return helper.counters[name]
        end

        ---Reads the fixture-owned observation count.
        ---@return integer
        local function read()
            return helper.counters[name]
        end

        return observe, read
    end

    return helper
end

---Asserts that a subject resolves to the exact mounted root instance.
---@param root table
---@param expected any
function M.assert_mounted_root(root, expected)
    assert(type(root) == 'table' and type(root.raw) == 'function',
        'mounted root assertion requires a Subject-like value')
    assert(root:raw() == expected,
        'mounted root subject does not retain exact instance identity')
end

---Captures pointer accessors, coordinates, and every physical button field.
---@param environment table|nil
---@return table
function M.pointer_snapshot(environment)
    environment = environment or {
        screen=dfhack.screen,
        gps=df.global.gps,
        enabler=df.global.enabler,
    }
    local state = {
        get_mouse_pos=environment.screen.getMousePos,
        get_mouse_pixels=environment.screen.getMousePixels,
        mouse_x=environment.gps.mouse_x,
        mouse_y=environment.gps.mouse_y,
        precise_mouse_x=environment.gps.precise_mouse_x,
        precise_mouse_y=environment.gps.precise_mouse_y,
    }
    for _, name in ipairs(POINTER_BUTTON_FIELDS) do
        state[name] = environment.enabler[name]
    end
    return state
end

---Asserts exact pointer accessor, coordinate, and button restoration.
---@param expected table
---@param actual table
function M.assert_pointer_restored(expected, actual)
    assert_flat_equal(expected, actual, 'pointer state')
end

---Asserts that default redraw waits through a new observed generation.
---@param read_generation function
---@param redraw function
---@return integer
function M.assert_default_wait_redraw(read_generation, redraw)
    assert(type(read_generation) == 'function',
        'default-wait redraw requires a generation reader')
    assert(type(redraw) == 'function',
        'default-wait redraw requires a redraw operation')
    local before = read_generation()
    redraw()
    local after = read_generation()
    assert(type(before) == 'number' and type(after) == 'number' and
        after > before,
        'default redraw must return after a newer render generation')
    return after
end

---Asserts immediate no-wait return and separately observed later rendering.
---@param read_generation function
---@param redraw function
---@param await_later function
---@return integer
function M.assert_no_wait_redraw(read_generation, redraw, await_later)
    assert(type(read_generation) == 'function',
        'no-wait redraw requires a generation reader')
    assert(type(redraw) == 'function',
        'no-wait redraw requires a redraw operation')
    assert(type(await_later) == 'function',
        'no-wait redraw requires a bounded later-render wait')
    local before = read_generation()
    redraw()
    assert(read_generation() == before,
        'no-wait redraw must return before the next render generation')
    await_later(before)
    local after = read_generation()
    assert(type(after) == 'number' and after > before,
        'no-wait redraw must complete a later render generation')
    return after
end

---Asserts bounded, rectangular screen-cell capture content.
---@param capture table
---@param max_width integer
---@param max_height integer
function M.assert_bounded_screen(capture, max_width, max_height)
    assert(type(capture) == 'table',
        'screen capture must be a table')
    assert(type(capture.width) == 'number' and capture.width >= 0 and
        capture.width <= max_width,
        'screen capture width exceeds its requested bound')
    assert(type(capture.height) == 'number' and capture.height >= 0 and
        capture.height <= max_height,
        'screen capture height exceeds its requested bound')
    assert(type(capture.cells) == 'table' and
        #capture.cells == capture.height,
        'screen capture rows must match its reported height')
    for _, row in ipairs(capture.cells) do
        assert(type(row) == 'table' and #row == capture.width,
            'screen capture cells must form a bounded rectangle')
        for _, cell in ipairs(row) do
            assert(type(cell) == 'table' and
                (cell.ch == nil or type(cell.ch) == 'number'),
                'screen capture must contain structured cells')
        end
    end
end

---Asserts bounded tree content with an exact root and at least one node.
---@param tree table
---@param expected_root any
---@param max_nodes integer
---@param max_depth integer
function M.assert_bounded_tree(tree, expected_root, max_nodes, max_depth)
    assert(type(max_nodes) == 'number' and max_nodes > 0 and
        max_nodes % 1 == 0,
        'tree node bound must be a positive integer')
    assert(type(max_depth) == 'number' and max_depth >= 0 and
        max_depth % 1 == 0,
        'tree depth bound must be a nonnegative integer')
    local node_count = 0

    ---Visits one captured node while enforcing the requested bounds.
    ---@param node table
    ---@param depth integer
    local function visit(node, depth)
        assert(type(node) == 'table',
            'captured tree node must be a table')
        assert(depth <= max_depth,
            'captured tree exceeds its requested depth bound')
        node_count = node_count + 1
        assert(node_count <= max_nodes,
            'captured tree exceeds its requested node bound')
        assert(node.children == nil or type(node.children) == 'table',
            'captured tree children must be a table when present')
        for _, child in ipairs(node.children or {}) do
            visit(child, depth + 1)
        end
    end

    visit(tree, 0)
    assert(tree.view_id == expected_root or tree.name == expected_root or
        tree.class == expected_root,
        'captured tree root does not match the expected bounded root')
end

return M
