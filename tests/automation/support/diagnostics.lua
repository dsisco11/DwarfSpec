-- Stable read-only view and screen diagnostics for live automation failures.

local M = {}

local DEFAULT_TREE_MAX_DEPTH = 8
local DEFAULT_TREE_MAX_NODES = 128

---Returns a scalar value or the result of a lazy widget property.
---@param value any
---@return any
local function get_value(value)
    if type(value) ~= 'function' then return value end
    local ok, result = pcall(value)
    return ok and result or '<unavailable>'
end

---Returns a stable class label without retaining userdata text addresses.
---@param view any
---@return string
local function class_name(view)
    local type_value = view and view._type
    if type(type_value) == 'string' then return type_value end
    if type(type_value) == 'table' then
        return type_value._name or type_value.name or '<view>'
    end
    return type(view)
end

---Copies one live rectangle into plain diagnostic coordinates.
---@param rect table|nil
---@return table|nil
local function copy_rect(rect)
    if not rect then return nil end
    return {
        x1=rect.x1,
        y1=rect.y1,
        x2=rect.x2,
        y2=rect.y2,
        clip_x1=rect.clip_x1,
        clip_y1=rect.clip_y1,
        clip_x2=rect.clip_x2,
        clip_y2=rect.clip_y2,
    }
end

---Returns a stable plain-text form of a widget text value.
---@param text any
---@return string|nil
local function text_value(text)
    if text == nil then return nil end
    if type(text) == 'string' then return text end
    if type(text) == 'number' or type(text) == 'boolean' then
        return tostring(text)
    end
    return '<' .. type(text) .. '>'
end

---Inspects one live view without mutating it.
---@param view table
---@return table
function M.inspect_view(view)
    assert(view, 'cannot inspect a nil view')
    local focused = not not view.focus
    if type(view.hasFocus) == 'function' then
        local ok, value = pcall(view.hasFocus, view)
        focused = ok and not not value
    end
    return {
        class=class_name(view),
        view_id=view.view_id,
        visible=not not get_value(view.visible),
        active=not not get_value(view.active),
        focused=focused,
        frame=copy_rect(view.frame_rect),
        body=copy_rect(view.frame_body),
        text=text_value(view.text),
        tooltip=text_value(view.tooltip),
    }
end

---Captures one bounded view subtree through ordered native child arrays.
---@param view table
---@param options table
---@param state table
---@param depth integer
---@return table
local function capture_view_subtree(view, options, state, depth)
    local node = M.inspect_view(view)
    node.children = {}
    state.node_count = state.node_count + 1
    if depth >= options.max_depth then
        if #(view.subviews or {}) > 0 then
            node.truncated = true
            state.truncated = true
        end
        return node
    end
    for _, child in ipairs(view.subviews or {}) do
        if state.node_count >= options.max_nodes then
            node.truncated = true
            state.truncated = true
            break
        end
        table.insert(node.children, capture_view_subtree(
            child, options, state, depth + 1))
    end
    return node
end

---Recursively captures a bounded view tree with explicit capture metadata.
---@param view table
---@param options table|nil
---@return table
function M.capture_view_tree(view, options)
    options = options or {}
    local bounds = {
        max_depth=options.max_depth or DEFAULT_TREE_MAX_DEPTH,
        max_nodes=options.max_nodes or DEFAULT_TREE_MAX_NODES,
    }
    assert(type(bounds.max_depth) == 'number' and bounds.max_depth >= 0 and
        bounds.max_depth % 1 == 0,
        'view-tree max depth must be a nonnegative integer')
    assert(type(bounds.max_nodes) == 'number' and bounds.max_nodes >= 1 and
        bounds.max_nodes % 1 == 0,
        'view-tree max nodes must be a positive integer')
    local state = {node_count=0, truncated=false}
    local root = capture_view_subtree(view, bounds, state, 0)
    root.capture_bounds = {
        max_depth=bounds.max_depth,
        max_nodes=bounds.max_nodes,
        node_count=state.node_count,
        truncated=state.truncated,
    }
    return root
end

---Captures a bounded plain screen-cell buffer through DFHack's read API.
---@param options table|nil
---@return table
function M.capture_screen(options)
    options = options or {}
    local width, height = dfhack.screen.getWindowSize()
    local max_width = math.min(width, options.max_width or width)
    local max_height = math.min(height, options.max_height or height)
    assert(max_width >= 1 and max_height >= 1,
        'screen capture dimensions must be positive')
    local result = {width=max_width, height=max_height, cells={}}
    for y = 0, max_height - 1 do
        local row = {}
        for x = 0, max_width - 1 do
            local pen = dfhack.screen.readTile(x, y)
            row[x + 1] = pen and {
                ch=pen.ch,
                fg=pen.fg,
                bg=pen.bg,
                bold=pen.bold,
                tile=pen.tile,
            } or nil
        end
        result.cells[y + 1] = row
    end
    return result
end

---Formats a compact fixture-tree summary for operational errors.
---@param node table
---@param depth integer|nil
---@return string
function M.summarize_tree(node, depth)
    depth = depth or 0
    local identifier = node.view_id and ('#' .. node.view_id) or ''
    local summary = string.rep('>', depth) .. node.class .. identifier
    for _, child in ipairs(node.children or {}) do
        summary = summary .. ',' .. M.summarize_tree(child, depth + 1)
    end
    return summary
end

---Captures bounded evidence for a failed mounted-component operation.
---@param mount table
---@param operation string
---@param failure any
---@return table
function M.capture_mount_failure(mount, operation, failure)
    local root = mount.host_screen or mount.root
    local tree = nil
    if root then
        local ok, value = pcall(M.capture_view_tree, root)
        if ok then tree = value end
    end
    local screen = {width=0, height=0, cells={}}
    local ok, value = pcall(M.capture_screen, {
        max_width=16,
        max_height=8,
    })
    if ok then screen = value end
    return {
        mount_id=mount.id,
        selected_mount_id=mount.command_subject and
            mount.command_subject.mount_id or nil,
        selected_control_path=mount.command_subject and
            mount.command_subject.control_path or nil,
        category=mount.category,
        operation=operation,
        cause=tostring(failure),
        tree=tree,
        screen=screen,
    }
end

---Formats original failure text with compact mount and screen diagnostics.
---@param evidence table
---@return string
function M.format_mount_failure(evidence)
    local tree_summary = evidence.tree and
        M.summarize_tree(evidence.tree) or '<none>'
    return ('DwarfSpec mount failure: operation=%q mount=%s category=%s ' ..
        'selected_control_path=%q selected_mount=%s cause=%s component_tree=%s ' ..
        'screen_capture=%dx%d')
        :format(evidence.operation, tostring(evidence.mount_id),
            tostring(evidence.category), evidence.selected_control_path,
            tostring(evidence.selected_mount_id), evidence.cause,
            tree_summary, evidence.screen.width, evidence.screen.height)
end

return M
