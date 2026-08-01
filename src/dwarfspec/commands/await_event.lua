-- Native DFHack state-change event awaiting.

local M = {}
local next_listener_id = 0

---Returns a bounded diagnostic representation of one public argument.
---@param value any
---@return string
local function bounded_value(value)
    local value_type = type(value)
    if value_type == 'string' then
        local bounded = value:sub(1, 80)
        if #value > #bounded then bounded = bounded .. '...' end
        return string.format('%q', bounded)
    end
    if value_type == 'nil' or value_type == 'number' or
            value_type == 'boolean' then
        return tostring(value)
    end
    return '<' .. value_type .. '>'
end

---Creates an immutable scalar record detached from its source table.
---@param values table
---@param label string
---@return table
local function immutable_record(values, label)
    local data = {}
    for name, value in pairs(values) do
        assert(type(name) == 'string',
            label .. ' field names must be strings')
        assert(value == nil or type(value) == 'string' or
                type(value) == 'number' or type(value) == 'boolean',
            label .. ' fields must be scalar values')
        if value ~= nil then data[name] = value end
    end
    return setmetatable({}, {
        __index=data,
        ---Rejects mutation of an immutable event record.
        __newindex=function()
            error(label .. ' is immutable', 2)
        end,
        ---Iterates detached event-record fields.
        ---@return function, table, nil
        __pairs=function()
            return pairs(data)
        end,
        __metatable=false,
    })
end

---Creates an immutable occurrence around one immutable payload snapshot.
---@param event string
---@param payload table
---@return table
local function immutable_occurrence(event, payload)
    local data = {
        event=event,
        source='state_change',
        payload=payload,
    }
    return setmetatable({}, {
        __index=data,
        ---Rejects mutation of an immutable event occurrence.
        __newindex=function()
            error('event occurrence is immutable', 2)
        end,
        ---Iterates detached event-occurrence fields.
        ---@return function, table, nil
        __pairs=function()
            return pairs(data)
        end,
        __metatable=false,
    })
end

---Reads one optional native value without allowing unavailability to fail.
---@param reader function
---@return any|nil
local function read_optional(reader)
    local ok, value = pcall(reader)
    if not ok then return nil end
    return value
end

---Normalizes one optional nonempty string field.
---@param value any
---@return string|nil
local function optional_string(value)
    if type(value) ~= 'string' or value == '' then return nil end
    return value
end

---Normalizes the first current native focus string.
---@param value any
---@return string|nil
local function focus_string(value)
    if type(value) == 'table' then value = value[1] end
    return optional_string(value)
end

---Normalizes one native screen type without retaining its screen.
---@param screen any
---@return string|nil
local function screen_type(screen)
    if screen == nil then return nil end
    local ok, value = pcall(function() return screen._type end)
    if not ok or value == nil then return nil end
    if type(value) == 'table' then
        return optional_string(value._name or value.name)
    end
    if type(value) == 'string' then return optional_string(value) end
    local rendered = tostring(value)
    return optional_string(rendered:match('^<type:%s*([^>]+)>$'))
end

---Validates public event-wait options before native listener registration.
---@param options any
---@return table
local function validate_options(options)
    if options == nil then return {} end
    assert(type(options) == 'table',
        'awaitEvent options must be a table; received ' ..
            bounded_value(options))
    for name in pairs(options) do
        assert(name == 'trigger' or name == 'description' or
                name == 'timeout_ms',
            'awaitEvent options contain unsupported field: ' ..
                bounded_value(name))
    end
    assert(options.trigger == nil or type(options.trigger) == 'function',
        'awaitEvent trigger must be a function')
    assert(options.description == nil or
            (type(options.description) == 'string' and
                options.description ~= ''),
        'awaitEvent description must be a nonempty string')
    assert(options.timeout_ms == nil or options.timeout_ms == false or
            (type(options.timeout_ms) == 'number' and
                options.timeout_ms >= 1 and
                options.timeout_ms % 1 == 0),
        'awaitEvent timeout_ms must be false or a positive integer')
    return options
end

---Constructs one run-scoped event-awaiting command from native dependencies.
---@param dependencies table
---@return fun(event:string, options:table|nil):table
function M.new(dependencies)
    assert(type(dependencies) == 'table',
        'awaitEvent command requires dependencies')
    local EEvent = assert(dependencies.events,
        'awaitEvent command requires public event identifiers')
    local state_changes = assert(dependencies.state_changes,
        'awaitEvent command requires DFHack state-change constants')
    local handlers = assert(dependencies.state_change_handlers,
        'awaitEvent command requires state-change handlers')
    local scheduler_module = assert(dependencies.scheduler_module,
        'awaitEvent command requires a scheduler module')
    local scheduler = assert(dependencies.scheduler,
        'awaitEvent command requires a scheduler')
    local read_save_directory = assert(dependencies.read_save_directory,
        'awaitEvent command requires save-directory access')
    local get_focus = assert(dependencies.get_focus,
        'awaitEvent command requires native focus access')
    local current_viewscreen = assert(dependencies.current_viewscreen,
        'awaitEvent command requires viewscreen access')

    local event_to_state = {
        [EEvent.WORLD_LOADED]=assert(state_changes.WORLD_LOADED,
            'awaitEvent requires SC_WORLD_LOADED'),
        [EEvent.WORLD_UNLOADED]=assert(state_changes.WORLD_UNLOADED,
            'awaitEvent requires SC_WORLD_UNLOADED'),
        [EEvent.MAP_LOADED]=assert(state_changes.MAP_LOADED,
            'awaitEvent requires SC_MAP_LOADED'),
        [EEvent.MAP_UNLOADED]=assert(state_changes.MAP_UNLOADED,
            'awaitEvent requires SC_MAP_UNLOADED'),
        [EEvent.VIEWSCREEN_CHANGED]=assert(state_changes.VIEWSCREEN_CHANGED,
            'awaitEvent requires SC_VIEWSCREEN_CHANGED'),
        [EEvent.PAUSED]=assert(state_changes.PAUSED,
            'awaitEvent requires SC_PAUSED'),
        [EEvent.UNPAUSED]=assert(state_changes.UNPAUSED,
            'awaitEvent requires SC_UNPAUSED'),
    }

    ---Creates a pointer-free normalized payload for one matching event.
    ---@param event string
    ---@param unload_save_directory string|nil
    ---@return table
    local function event_payload(event, unload_save_directory)
        local payload = {}
        if event == EEvent.WORLD_LOADED or event == EEvent.MAP_LOADED then
            payload.save_directory = optional_string(
                read_optional(read_save_directory))
        elseif event == EEvent.WORLD_UNLOADED or
                event == EEvent.MAP_UNLOADED then
            payload.save_directory = unload_save_directory
        elseif event == EEvent.VIEWSCREEN_CHANGED then
            payload.focus = focus_string(read_optional(get_focus))
            payload.native_screen_type =
                screen_type(read_optional(current_viewscreen))
        elseif event == EEvent.PAUSED then
            payload.paused = true
        elseif event == EEvent.UNPAUSED then
            payload.paused = false
        end
        return immutable_record(payload, 'event payload')
    end

    ---Waits for the next matching native state-change event occurrence.
    ---@param event string
    ---@param options table|nil
    ---@return table
    local function await_event(event, options)
        local native_state = event_to_state[event]
        assert(native_state ~= nil,
            'awaitEvent does not support event: ' .. bounded_value(event))
        options = validate_options(options)

        local unload_save_directory
        if event == EEvent.WORLD_UNLOADED or
                event == EEvent.MAP_UNLOADED then
            unload_save_directory = optional_string(
                read_optional(read_save_directory))
        end

        next_listener_id = next_listener_id + 1
        local listener_key = ('dwarfspec.awaitEvent.%d')
            :format(next_listener_id)
        local installed = false

        ---Removes this command's native listener at most once.
        local function cleanup_listener()
            if not installed then return end
            installed = false
            handlers[listener_key] = nil
        end

        return scheduler_module.wait_event(scheduler, event, {
            description=options.description,
            timeout_ms=options.timeout_ms,
            cleanup=cleanup_listener,
            arm=function(wait_identity)
                handlers[listener_key] = function(state)
                    if state ~= native_state then return end
                    local payload = event_payload(
                        event, unload_save_directory)
                    local occurrence =
                        immutable_occurrence(event, payload)
                    if scheduler_module.signal_event(
                            scheduler, wait_identity, occurrence) then
                        cleanup_listener()
                    end
                end
                installed = true
                if options.trigger then options.trigger() end
            end,
        })
    end

    return await_event
end

return M
