-- Deliberately failing fixture used to prove host-side recovery diagnostics.

local M = {}

---Raises the controlled fixture-construction failure.
---@return table
function M.new()
    error('deliberate automation fixture construction failure')
end

return M
