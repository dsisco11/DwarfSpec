-- Live-game interaction namespace exported into isolated Busted specs.

local M = {}

---Creates the run-scoped live interaction namespace.
---@param scheduler_module table
---@param scheduler table
---@param cleanup_module table
---@param cleanup_registry table
---@return table
function M.new(scheduler_module, scheduler, cleanup_module, cleanup_registry)
    local dy = {
        protocol_version=1,
    }

    ---Waits for actual DFHack raw-frame callbacks without blocking the game.
    ---@param count integer
    ---@param options table|nil
    ---@return integer
    function dy.wait_frames(count, options)
        return scheduler_module.wait_frames(scheduler, count, options)
    end

    ---Polls a read-only condition once per frame until it becomes ready.
    ---@param description string
    ---@param query function
    ---@param options table|nil
    ---@return any
    function dy.wait_until(description, query, options)
        return scheduler_module.wait_until(
            scheduler, description, query, options)
    end

    ---Restores all currently registered test-owned resources.
    function dy.reset()
        local ok, failures = cleanup_module.run(cleanup_registry, 'dy.reset')
        if not ok then
            local messages = {}
            for _, failure in ipairs(failures) do
                table.insert(messages, failure.name .. ': ' .. failure.message)
            end
            error('automation cleanup failed: ' .. table.concat(messages, '; '),
                2)
        end
    end

    return dy
end

return M
