-- Reversible instance-level render interception.

local M = {}

---Installs render completion tracking while preserving effective behavior.
---@param target table
---@param tracker table
---@param enrich_failure function|nil
---@return function
function M.install(target, tracker, enrich_failure)
    assert(type(target) == 'table',
        'render instrumentation target must be a table')
    assert(type(target.onRender) == 'function',
        'render instrumentation target must provide onRender()')
    assert(type(tracker) == 'table' and
        type(tracker.completed) == 'function' and
        type(tracker.failed) == 'function',
        'render instrumentation requires a render tracker')
    assert(enrich_failure == nil or type(enrich_failure) == 'function',
        'render failure enricher must be a function')

    local original_instance_method = rawget(target, 'onRender')
    local original_effective_method = target.onRender
    local installed_method
    installed_method = function(self, ...)
        local arguments = table.pack(...)
        local results = table.pack(xpcall(function()
            return original_effective_method(self,
                table.unpack(arguments, 1, arguments.n))
        end, debug.traceback))
        if not results[1] then
            local original_failure = results[2]
            local reported_failure = original_failure
            if enrich_failure then
                local ok, enriched = pcall(enrich_failure, original_failure)
                if ok and enriched ~= nil then reported_failure = enriched end
            end
            tracker:failed(reported_failure)
            error(reported_failure, 0)
        end
        tracker:completed()
        return table.unpack(results, 2, results.n)
    end
    rawset(target, 'onRender', installed_method)

    local restored = false

    ---Restores the exact instance-level render method present at installation.
    ---@return boolean
    return function()
        if restored then return false end
        assert(rawget(target, 'onRender') == installed_method,
            'instrumented onRender changed before restoration')
        rawset(target, 'onRender', original_instance_method)
        restored = true
        return true
    end
end

return M
