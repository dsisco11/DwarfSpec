-- Screen-capture command bindings for one DwarfSpec run.

local M = {}

---Binds screen capture to the public run-scoped namespace.
---@param ds table
---@param dependencies table
function M.bind(ds, dependencies)
    ---Captures and retains a bounded plain screen-cell buffer.
    ---@param name string
    ---@param options table|nil
    ---@return table
    function ds.capture_screen(name, options)
        assert(type(name) == 'string' and name:match('^[%w_.-]+$'),
            'capture name must be a relative identifier')
        dependencies.run.captures = dependencies.run.captures or {}
        local capture = dependencies.diagnostics.capture_screen(options)
        dependencies.run.captures[name] = capture
        return capture
    end
end

return M
