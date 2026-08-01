-- Public keyboard and text-input command bindings.

local M = {}

---Creates keyboard and text-input commands for one run-scoped namespace.
---@param dependencies table
---@return table
function M.new(dependencies)
    assert(type(dependencies.resolve_target) == 'function' and
        type(dependencies.simulate_input) == 'function',
        'DwarfSpec input commands require target resolution and input dispatch')
    local context = dependencies.context
    return {
        ---Sends supported native input and waits for the live screen to settle.
        ---@param keys string|table
        ---@param subject table|nil
        ---@return integer
        input=function(keys, subject)
            local _, target = dependencies.resolve_target(subject, 'input')
            return context.mount_context:mutate('input', function()
                dependencies.simulate_input(target, 'input', keys)
            end)
        end,
        ---Types ASCII text through DFHack's supported string keycodes.
        ---@param text string
        ---@param subject table|nil
        ---@return integer
        type=function(text, subject)
            local _, target = dependencies.resolve_target(subject, 'type')
            return context.mount_context:mutate('type', function()
                assert(type(text) == 'string', 'text input must be a string')
                for index = 1, #text do
                    assert(text:byte(index) >= 1,
                        'text input cannot contain NUL bytes')
                    dependencies.simulate_input(target, 'type',
                        ('STRING_A%03d'):format(text:byte(index)))
                end
            end)
        end,
    }
end

return M
