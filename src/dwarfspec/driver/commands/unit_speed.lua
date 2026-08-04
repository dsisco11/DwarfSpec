-- Public binding for run-owned unit-speed behavior.

local M = {}

---Binds unit-speed activation to the public run-scoped namespace.
---@param ds table
---@param dependencies table
function M.bind(ds, dependencies)
    assert(type(ds) == 'table', 'unit speed command requires ds namespace')
    local controller = assert(dependencies.controller,
        'unit speed command requires controller')

    ---Activates selected unit-speed behaviors for this example.
    ---@param options table
    function ds.setUnitSpeed(options)
        controller:activate(options)
    end
end

return M
