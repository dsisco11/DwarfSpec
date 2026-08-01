-- Private render completion tracking for one mounted component.

local M = {}

---Creates a tracker whose waits are driven by the live automation scheduler.
---@param scheduler_module table
---@param scheduler table
---@param options table|nil
---@return table
function M.new(scheduler_module, scheduler, options)
    assert(type(scheduler_module) == 'table' and
        type(scheduler_module.wait_until) == 'function',
        'render tracker requires scheduler wait support')
    assert(type(scheduler) == 'table',
        'render tracker requires an automation scheduler')
    options = options or {}

    local tracker = {
        scheduler_module=scheduler_module,
        scheduler=scheduler,
        wait_options=options.wait_options,
        _generation=0,
        _failure=nil,
    }

    ---Returns the current private render generation.
    ---@return integer
    function tracker:generation()
        return self._generation
    end

    ---Captures the generation before an operation that must render.
    ---@return integer
    function tracker:capture()
        self._failure = nil
        return self._generation
    end

    ---Records one successfully completed render.
    ---@return integer
    function tracker:completed()
        self._failure = nil
        self._generation = self._generation + 1
        return self._generation
    end

    ---Records a render failure without advancing the generation.
    ---@param message any
    function tracker:failed(message)
        self._failure = tostring(message)
    end

    ---Waits until a render completes after the captured generation.
    ---@param captured_generation integer
    ---@param description string|nil
    ---@return integer
    function tracker:wait_after(captured_generation, description)
        assert(type(captured_generation) == 'number',
            'captured render generation must be a number')
        return self.scheduler_module.wait_until(
            self.scheduler, description or 'component render', function()
                if self._failure then error(self._failure, 0) end
                if self._generation > captured_generation then
                    return self._generation
                end
                return false
            end, self.wait_options)
    end

    return tracker
end

return M
