-- Wait command bindings for one DwarfSpec run.

local M = {}

---Binds wait commands to the public run-scoped namespace.
---@param ds table
---@param dependencies table
function M.bind(ds, dependencies)
    local function options_for(options, include_frame_budget)
        local result = {}
        for key, value in pairs(options or {}) do result[key] = value end
        if result.timeout_ms == nil then
            result.timeout_ms = dependencies.wait_settings.timeout_ms
        end
        if include_frame_budget and result.frame_budget == nil then
            result.frame_budget = dependencies.wait_settings.frame_budget
        end
        return result
    end

    ---Waits for actual DFHack raw-frame callbacks without blocking the game.
    ---@param count integer
    ---@param options table|nil
    ---@return integer
    function ds.wait_frames(count, options)
        return dependencies.scheduler_module.wait_frames(
            dependencies.scheduler, count, options_for(options, false))
    end

    ---Waits for unpaused Dwarf Fortress simulation ticks without blocking.
    ---@param count integer
    ---@param options table|nil
    ---@return integer
    function ds.wait_ticks(count, options)
        return dependencies.scheduler_module.wait_ticks(
            dependencies.scheduler, count, options_for(options, false))
    end

    ---Polls a read-only condition once per frame until it becomes ready.
    ---@param description string
    ---@param query function
    ---@param options table|nil
    ---@return any
    function ds.await(description, query, options)
        return dependencies.scheduler_module.wait_until(dependencies.scheduler,
            description, query, options_for(options, true))
    end

    ---Waits for and returns the next occurrence of one native event.
    ---@param event DwarfSpecEEvent
    ---@param options DwarfSpecAwaitEventOptions|nil
    ---@return DwarfSpecEventOccurrence
    function ds.awaitEvent(event, options)
        return dependencies.await_event(event, options)
    end
end

return M
