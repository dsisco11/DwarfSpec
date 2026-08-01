-- Generation-guarded run-event publication and transport encoding.

local M = {}

---Creates a generation-bound publisher for one active service run.
---@param run table
---@param dependencies table
---@return table
function M.new_publisher(run, dependencies)
    assert(type(dependencies.now_ms) == 'function' and
        type(dependencies.publish_active_event) == 'function',
        'transport publication requires time and service publication adapters')
    return {
        now_ms=dependencies.now_ms,
        publish=function(event_type, payload)
            return dependencies.publish_active_event(run.run_id,
                run.generation, event_type, payload)
        end,
    }
end

---Publishes a run event through its active generation publisher.
---@param run table
---@param event_type any
---@param payload table
function M.publish(run, event_type, payload)
    assert(type(run.event_publisher) == 'table' and type(run.event_publisher.publish) == 'function',
        'active run does not own an event publisher')
    return run.event_publisher.publish(event_type, payload)
end

---Encodes one canonical transport envelope.
---@param transport table
---@param null any
---@param encoder table|nil
---@return string
function M.encode(transport, null, encoder)
    return (encoder or require('json')).encode(transport,
        {pretty=false, null=null})
end

return M
