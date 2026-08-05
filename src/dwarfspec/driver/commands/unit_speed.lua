-- Public binding for run-owned unit-speed behavior.

local M = {}

---Binds unit-speed activation to the public run-scoped namespace.
---@param ds table
---@param dependencies table
function M.bind(ds, dependencies)
    assert(type(ds) == 'table', 'unit speed command requires ds namespace')
    local controller = assert(dependencies.controller,
        'unit speed command requires controller')
    local enable_fast_movement = assert(dependencies.enable_fast_movement,
        'unit speed command requires fast-movement enabler')
    assert(type(enable_fast_movement) == 'function',
        'unit speed fast-movement enabler must be a function')

    ---Activates selected unit-speed behaviors for this example.
    ---@param options table
    function ds.setUnitSpeed(options)
        if controller:activate(options) then
            enable_fast_movement()
        end
    end
end

return M
