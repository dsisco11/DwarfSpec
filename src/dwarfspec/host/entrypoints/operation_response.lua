-- Canonical success-or-rejection emission for mutation adapters.

local adapter_errors = require('dwarfspec.protocol.adapter_errors')
local RunnerFailureKind =
    require('dwarfspec.protocol.enums.runner_failure_kinds')

local M = {}

---Runs one adapter operation and emits exactly one canonical JSON response.
---@param operation function
---@param emit_success function
---@param encoder function
---@return boolean, any
function M.execute(operation, emit_success, encoder)
    local succeeded, value = pcall(operation)
    if not succeeded then
        if type(value) ~= 'table' or type(value.code) ~= 'string' or
                value.code == '' then
            error(value, 0)
        end
        local encoded = adapter_errors.serialize(
            value, RunnerFailureKind.HOST, encoder)
        print('DWARFSPEC_JSON ' .. encoded)
        return false, value
    end
    emit_success(value)
    return true, value
end

return M
