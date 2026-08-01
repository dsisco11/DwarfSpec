-- Reversible observation of native viewscreen-plus-overlay render completion.

local M = {}

---Returns a failure enriched for the current mount when possible.
---@param failure any
---@param enrich_failure function|nil
---@return any
local function enrich(failure, enrich_failure)
    if not enrich_failure then return failure end
    local ok, enriched = pcall(enrich_failure, failure)
    if ok and enriched ~= nil then return enriched end
    return failure
end

---Installs a run-scoped observer around DFHack's overlay render dispatcher.
---@param overlay table
---@param pinned_screen any
---@param tracker table
---@param enrich_failure function|nil
---@param on_completed function|nil
---@return function
function M.install(overlay, pinned_screen, tracker, enrich_failure, on_completed)
    assert(type(overlay) == 'table',
        'native render observation requires the DFHack overlay module')
    assert(pinned_screen ~= nil,
        'native render observation requires a pinned viewscreen')
    assert(type(overlay.render_viewscreen_widgets) == 'function',
        'DFHack overlay dispatch is unavailable: ' ..
            'plugins.overlay.render_viewscreen_widgets is not a function')
    assert(type(tracker) == 'table' and
        type(tracker.completed) == 'function' and
        type(tracker.failed) == 'function',
        'native render observation requires a render tracker')
    assert(enrich_failure == nil or type(enrich_failure) == 'function',
        'native render failure enricher must be a function')
    assert(on_completed == nil or type(on_completed) == 'function',
        'native render completion callback must be a function')

    local original = overlay.render_viewscreen_widgets
    local installed
    installed = function(...)
        local arguments = table.pack(...)
        local relevant = arguments[2] == pinned_screen
        local results = table.pack(pcall(original,
            table.unpack(arguments, 1, arguments.n)))
        if not results[1] then
            local failure = results[2]
            if relevant then
                failure = enrich(failure, enrich_failure)
                tracker:failed(failure)
            end
            error(failure, 0)
        end
        if relevant then
            local observed = table.pack(xpcall(function()
                if on_completed then on_completed() end
                return tracker:completed()
            end, debug.traceback))
            if not observed[1] then
                local failure = enrich(observed[2], enrich_failure)
                tracker:failed(failure)
                error(failure, 0)
            end
        end
        return table.unpack(results, 2, results.n)
    end
    overlay.render_viewscreen_widgets = installed

    local restored = false

    ---Restores the exact dispatcher captured at installation.
    ---@return boolean
    return function()
        if restored then return false end
        assert(overlay.render_viewscreen_widgets == installed,
            'native render dispatcher changed before restoration')
        overlay.render_viewscreen_widgets = original
        restored = true
        return true
    end
end

return M
