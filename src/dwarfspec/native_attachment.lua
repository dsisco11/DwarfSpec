-- Validated non-owning attachment to the exact current native DF viewscreen.

local M = {}

---@class dwarfspec.NativeAttachment
---@field _get_current_viewscreen function
---@field _get_native_viewscreen function
---@field _is_widget_root function
---@field _interaction_target_factory function
---@field _subject_source_factory function
local NativeAttachment = {}
NativeAttachment.__index = NativeAttachment

---Calls one injected viewscreen getter with an explicit capability error.
---@param getter function
---@param label string
---@return any
local function acquire_screen(getter, label)
    local ok, screen = pcall(getter)
    assert(ok,
        ('DwarfSpec native mount could not query the %s viewscreen: %s')
            :format(label, tostring(screen)))
    return screen
end

---Validates and pins a current native screen before returning mount resources.
---@return table
function NativeAttachment:attach()
    local current = acquire_screen(
        self._get_current_viewscreen, 'current')
    assert(current ~= nil,
        'DwarfSpec native mount requires a current viewscreen')
    local native = acquire_screen(
        self._get_native_viewscreen, 'native DF')
    assert(native ~= nil,
        'DwarfSpec native mount requires a native DF viewscreen')
    assert(current == native,
        'DwarfSpec native mount requires the current viewscreen to be the ' ..
        'native DF viewscreen; a DFHack Lua screen currently owns focus')

    local root_ok, root = pcall(function() return current.widgets end)
    assert(root_ok,
        'DwarfSpec native mount could not read the current viewscreen ' ..
            'widgets container: ' .. tostring(root))
    assert(self._is_widget_root(root),
        'DwarfSpec native mount requires the current viewscreen to expose a ' ..
            'valid widgets container')

    local interaction_target =
        self._interaction_target_factory(current)
    local source_ok, subject_source = xpcall(function()
        return self._subject_source_factory(root, interaction_target)
    end, debug.traceback)
    if not source_ok then
        local message = tostring(subject_source)
        if interaction_target and
                type(interaction_target.cleanup) == 'function' then
            local cleanup_ok, cleanup_failure =
                xpcall(function()
                    interaction_target:cleanup()
                end, debug.traceback)
            if not cleanup_ok then
                message = message .. '; partial target cleanup failed: ' ..
                    tostring(cleanup_failure)
            end
        end
        error(message, 0)
    end
    return {
        root=root,
        pinned_screen=current,
        interaction_target=interaction_target,
        subject_source=subject_source,
    }
end

---Creates a native attachment service from injected read-only capabilities.
---@param options table
---@return dwarfspec.NativeAttachment
function M.new(options)
    assert(type(options) == 'table',
        'native attachment requires dependency options')
    assert(type(options.get_current_viewscreen) == 'function',
        'native attachment requires current-screen access')
    assert(type(options.get_native_viewscreen) == 'function',
        'native attachment requires native-screen access')
    assert(type(options.is_widget_root) == 'function',
        'native attachment requires widget-root validation')
    assert(type(options.interaction_target_factory) == 'function',
        'native attachment requires an interaction target factory')
    assert(type(options.subject_source_factory) == 'function',
        'native attachment requires a subject source factory')
    return setmetatable({
        _get_current_viewscreen=options.get_current_viewscreen,
        _get_native_viewscreen=options.get_native_viewscreen,
        _is_widget_root=options.is_widget_root,
        _interaction_target_factory=options.interaction_target_factory,
        _subject_source_factory=options.subject_source_factory,
    }, NativeAttachment)
end

return M
