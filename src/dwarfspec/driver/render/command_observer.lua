-- Command-boundary event publication and mount diagnostics.

local M = {}

---Creates an observer for public command boundaries.
---@param publisher table|nil
---@param event_type table
---@param test_status table
---@return table
function M.new(publisher, event_type, test_status)
    local function publish(kind, payload)
        if publisher then publisher.publish(kind, payload) end
    end
    local function bounded_text(value)
        local text = tostring(value)
        if #text <= 8192 then return text end
        return text:sub(1, 8189) .. '...'
    end
    local function subject_identity(subject)
        return ('mount:%s/%s'):format(
            tostring(subject.mount_id), tostring(subject.control_path))
    end
    return {
        ---Publishes one command start and returns its timing identity.
        ---@param name string
        ---@param subject table
        ---@return table
        started=function(name, subject)
            local started_ms = publisher and publisher.now_ms() or 0
            publish(event_type.COMMAND_STARTED, {
                name=name, subject_identity=subject_identity(subject),
                safe_arguments={},
            })
            return {name=name, started_ms=started_ms}
        end,
        ---Publishes one command result and bounded failure diagnostics.
        ---@param observation table
        ---@param ok boolean
        ---@param failure any|nil
        finished=function(observation, ok, failure)
            local finished_ms = publisher and publisher.now_ms() or
                observation.started_ms
            publish(event_type.COMMAND_FINISHED, {
                name=observation.name,
                status=ok and test_status.SUCCESS or test_status.ERROR,
                duration_ms=math.max(0, finished_ms - observation.started_ms),
            })
            if not ok then
                publish(event_type.DIAGNOSTIC_RECORDED, {
                    kind='command_failure', content={name=observation.name,
                        message=bounded_text(failure)},
                })
            end
        end,
    }
end

return M
