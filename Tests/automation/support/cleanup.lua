-- Idempotent LIFO cleanup registry for live automation resources.

local M = {}

---Creates an empty cleanup registry associated with one automation run.
---@param run table
---@return table
function M.new(run)
    return {
        run=run,
        entries={},
        next_id=0,
        cleaning=false,
        reset_count=0,
        failures={},
    }
end

---Registers one idempotently owned cleanup action.
---@param registry table
---@param name string
---@param action function
---@return table
function M.push(registry, name, action)
    assert(type(name) == 'string' and name ~= '',
        'cleanup action name must be a nonempty string')
    assert(type(action) == 'function', 'cleanup action must be a function')
    assert(not registry.cleaning,
        'cleanup actions cannot be registered while cleanup is running')
    registry.next_id = registry.next_id + 1
    local entry = {
        id=registry.next_id,
        registry=registry,
        name=name,
        action=action,
        state='pending',
    }
    table.insert(registry.entries, entry)
    return entry
end

---Releases one pending action without executing it.
---@param registry table
---@param entry table
---@return boolean
function M.release(registry, entry)
    assert(entry.registry == registry,
        'cleanup action belongs to a different registry')
    if entry.state ~= 'pending' then return false end
    entry.state = 'released'
    for index = #registry.entries, 1, -1 do
        if registry.entries[index] == entry then
            table.remove(registry.entries, index)
            break
        end
    end
    return true
end

---Returns the number of cleanup actions that remain pending.
---@param registry table
---@return integer
function M.pending_count(registry)
    return #registry.entries
end

---Executes and removes every pending action in strict reverse order.
---@param registry table
---@param reason string
---@return boolean, table[]
function M.run(registry, reason)
    assert(type(reason) == 'string' and reason ~= '',
        'cleanup reason must be a nonempty string')
    if registry.cleaning then
        return false, {{name='cleanup registry', message='cleanup is recursive'}}
    end

    registry.cleaning = true
    registry.reset_count = registry.reset_count + 1
    local failures = {}
    while #registry.entries > 0 do
        local entry = table.remove(registry.entries)
        if entry.state == 'pending' then
            entry.state = 'running'
            local ok, cleanup_error = xpcall(entry.action, debug.traceback)
            if ok then
                entry.state = 'complete'
            else
                entry.state = 'failed'
                entry.error = tostring(cleanup_error)
                local failure = {
                    id=entry.id,
                    name=entry.name,
                    message=entry.error,
                    reason=reason,
                }
                table.insert(failures, failure)
                table.insert(registry.failures, failure)
            end
        end
    end
    registry.cleaning = false
    return #failures == 0, failures
end

return M
