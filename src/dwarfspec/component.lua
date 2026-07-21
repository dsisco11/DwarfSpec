-- Product-independent component input and mount-option contracts.

local M = {}

local DEFAULT_VIEWPORT = {width=128, height=64}

M.DEFAULT_VIEWPORT = {width=128, height=64}

M.PUBLIC_API = {
    mount_context={'mount', 'root', 'unmount', 'viewport'},
    subject={
        'click', 'hover', 'move_pointer', 'input', 'type',
        'inspect', 'text', 'raw',
    },
}

M.FAILURE_OWNERSHIP = {
    construction='mount_failure',
    initialization='mount_failure',
    first_render='mount_failure',
    infrastructure='host_error',
}

local RESERVED_OPTIONS = {
    backing_viewscreen=true,
    initial_pause=true,
    overlay_position=true,
    viewport=true,
}

---Returns whether a value is a callable DFHack defclass table.
---@param value any
---@return boolean
local function is_class(value)
    if type(value) ~= 'table' or rawget(value, '__index') ~= value or
            type(rawget(value, 'ATTRS')) ~= 'table' then
        return false
    end
    local metatable = getmetatable(value)
    return type(metatable) == 'table' and
        type(metatable.__call) == 'function'
end

---Returns whether a class descends from an expected DFHack base class.
---@param class table
---@param expected table
---@return boolean
local function derives_from(class, expected)
    local current = class
    while is_class(current) do
        if current == expected then return true end
        current = rawget(current, 'super')
    end
    return false
end

---Returns a stable description for an unsupported component input.
---@param value any
---@return string
local function describe_value(value)
    if type(value) == 'table' then
        return is_class(value) and 'unsupported DFHack class' or
            'table that is not a supported DFHack component instance'
    end
    return type(value)
end

---Copies a table without sharing its mutable top-level container.
---@param source table
---@return table
local function copy_table(source)
    local result = {}
    for key, value in pairs(source) do result[key] = value end
    return result
end

---Validates and copies a deterministic component viewport.
---@param viewport table|nil
---@return table
local function normalize_viewport(viewport)
    if viewport == nil then
        return {
            width=DEFAULT_VIEWPORT.width,
            height=DEFAULT_VIEWPORT.height,
        }
    end
    assert(type(viewport) == 'table',
        'mount option viewport must be a table with width and height')
    assert(type(viewport.width) == 'number' and viewport.width >= 1 and
        viewport.width % 1 == 0,
        'mount option viewport.width must be a positive integer')
    assert(type(viewport.height) == 'number' and viewport.height >= 1 and
        viewport.height % 1 == 0,
        'mount option viewport.height must be a positive integer')
    return {width=viewport.width, height=viewport.height}
end

---Validates and copies an optional one-based overlay position.
---@param position table|nil
---@return table|nil
local function normalize_overlay_position(position)
    if position == nil then return nil end
    assert(type(position) == 'table',
        'mount option overlay_position must be a table with x and y')
    for _, axis in ipairs({'x', 'y'}) do
        local value = position[axis]
        assert(type(value) == 'number' and value % 1 == 0,
            ('mount option overlay_position.%s must be an integer')
                :format(axis))
    end
    return {
        x=position.x == 0 and 1 or position.x,
        y=position.y == 0 and 1 or position.y,
    }
end

---Returns component attribute names in deterministic diagnostic order.
---@param attributes table
---@return string[]
local function attribute_names(attributes)
    local names = {}
    for name in pairs(attributes) do table.insert(names, tostring(name)) end
    table.sort(names)
    return names
end

---Creates a component-boundary contract from the live DFHack base classes.
---@param types table
---@return table
function M.new(types)
    assert(type(types) == 'table',
        'component boundary requires DFHack component base classes')
    for _, name in ipairs({'Widget', 'OverlayWidget', 'ZScreen'}) do
        assert(is_class(types[name]),
            'component boundary requires DFHack class ' .. name)
    end
    assert(derives_from(types.OverlayWidget, types.Widget),
        'OverlayWidget must derive from Widget')

    local boundary = {}

    ---Validates and copies viewport dimensions for one component mount.
    ---@param viewport table|nil
    ---@return table
    function boundary:normalize_viewport(viewport)
        return normalize_viewport(viewport)
    end

    ---Classifies one supported component class or already-created instance.
    ---@param value any
    ---@return table
    function boundary:classify(value)
        local input_form
        local class
        if is_class(value) then
            input_form = 'class'
            class = value
        elseif type(value) == 'table' and is_class(getmetatable(value)) then
            input_form = 'instance'
            class = getmetatable(value)
        else
            error(('unsupported component input (%s); expected a DFHack ' ..
                'defclass derived from widgets.Widget, ' ..
                'overlay.OverlayWidget, or gui.ZScreen, or an instance of ' ..
                'one of those classes'):format(describe_value(value)), 2)
        end

        local category
        if derives_from(class, types.OverlayWidget) then
            category = 'overlay'
        elseif derives_from(class, types.Widget) then
            category = 'widget'
        elseif derives_from(class, types.ZScreen) then
            category = 'screen'
        else
            error(('unsupported component input (%s); DFHack class must ' ..
                'derive from widgets.Widget, overlay.OverlayWidget, or ' ..
                'gui.ZScreen'):format(describe_value(value)), 2)
        end
        return {category=category, input_form=input_form, class=class}
    end

    ---Normalizes common harness options and constructor attributes.
    ---@param options table|nil
    ---@return table
    function boundary:normalize_options(options)
        assert(options == nil or type(options) == 'table',
            'mount options must be a table or nil')
        options = options or {}
        local initial_pause = options.initial_pause
        assert(initial_pause == nil or type(initial_pause) == 'boolean',
            'mount option initial_pause must be a boolean')
        local backing_viewscreen = options.backing_viewscreen
        assert(backing_viewscreen == nil or
            type(backing_viewscreen) == 'table' or
            type(backing_viewscreen) == 'userdata',
            'mount option backing_viewscreen must be a DFHack viewscreen')

        local attributes = {}
        for key, value in pairs(options) do
            assert(type(key) == 'string' and key ~= '',
                'mount option names must be nonempty strings')
            if not RESERVED_OPTIONS[key] then attributes[key] = value end
        end
        return {
            attributes=attributes,
            backing_viewscreen=backing_viewscreen,
            initial_pause=initial_pause == nil and true or initial_pause,
            overlay_position=normalize_overlay_position(
                options.overlay_position),
            viewport=self:normalize_viewport(options.viewport),
        }
    end

    ---Resolves a supported input into one initialized component instance.
    ---@param value any
    ---@param options table|nil
    ---@return table
    function boundary:prepare(value, options)
        local classification = self:classify(value)
        local normalized = self:normalize_options(options)
        assert(classification.category == 'overlay' or
            normalized.overlay_position == nil,
            'mount option overlay_position is only valid for OverlayWidget ' ..
                'components')
        if classification.input_form == 'instance' then
            local names = attribute_names(normalized.attributes)
            assert(#names == 0,
                'mount options cannot set component attributes for an ' ..
                'already-created instance: ' .. table.concat(names, ', '))
            classification.component = value
        else
            local constructor_attributes = copy_table(normalized.attributes)
            if classification.category == 'screen' then
                constructor_attributes.initial_pause =
                    normalized.initial_pause
            end
            local ok, component = pcall(value, constructor_attributes)
            if not ok then
                error(('DwarfSpec mount failed while constructing %s ' ..
                    'component: %s'):format(classification.category,
                    tostring(component)), 2)
            end
            local created = self:classify(component)
            assert(created.input_form == 'instance' and
                created.category == classification.category,
                'component class did not create an instance of itself')
            classification.component = component
        end
        classification.options = normalized
        return classification
    end

    return boundary
end

return M
