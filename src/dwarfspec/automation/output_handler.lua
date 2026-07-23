-- In-memory Busted output handler for live automation runs.

local EventType = require('dwarfspec.automation.event_types')

local M = {}

---Publishes one structured Busted event when a publisher is configured.
---@param publisher table|nil
---@param event_type DwarfSpecEventType
---@param payload table
local function publish(publisher, event_type, payload)
    if publisher == nil then return end
    assert(type(publisher) == 'table' and
        type(publisher.publish) == 'function',
        'Busted event publisher must provide publish')
    publisher.publish(event_type, payload)
end

---Returns the publisher's monotonic timestamp when available.
---@param publisher table|nil
---@return number
local function publisher_time(publisher)
    if publisher == nil or publisher.now_ms == nil then return 0 end
    assert(type(publisher.now_ms) == 'function',
        'Busted event publisher now_ms must be a function')
    local value = publisher.now_ms()
    assert(type(value) == 'number' and value >= 0,
        'Busted event publisher returned an invalid timestamp')
    return value
end

---Appends one stable progress line to a run.
---@param run table
---@param line string
local function append_line(run, line)
    table.insert(run.output_lines, line)
end

---Converts a Busted trace value into stable printable text.
---@param trace any
---@return string|nil
local function trace_text(trace)
    if type(trace) == 'string' then return trace end
    if type(trace) ~= 'table' then return nil end
    return trace.traceback or trace.short_src
end

---Copies an ordinary Busted failure or error into the live run object.
---@param run table
---@param kind string
---@param handler table
---@param element table
---@param message any
---@param trace any
local function record_problem(run, kind, handler, element, message, trace)
    local detail = {
        kind=kind,
        name=handler.getFullName(element),
        message=tostring(message),
        trace=trace_text(trace),
    }
    table.insert(run.failure_details, detail)
    append_line(run, ('%s %s: %s'):format(
        kind:upper(), detail.name, detail.message))
end

---Creates and subscribes a Busted base handler backed by an in-memory run.
---@param busted table
---@param run table
---@param publisher table|nil
---@return table
function M.new(busted, run, publisher)
    local handler = require('busted.outputHandlers.base')()
    local base_suite_reset = handler.baseSuiteReset
    local base_suite_start = handler.baseSuiteStart
    local base_suite_end = handler.baseSuiteEnd
    local base_test_start = handler.baseTestStart
    local base_test_end = handler.baseTestEnd
    local base_test_failure = handler.baseTestFailure
    local base_test_error = handler.baseTestError
    local base_error = handler.baseError

    ---Resets result counts before another standard Busted repeat.
    function handler.baseSuiteReset(...)
        local first, second = base_suite_reset(...)
        run.counts = {successes=0, failures=0, errors=0, pending=0}
        run.current_test = nil
        return first, second
    end

    ---Records the start of one Busted repeat.
    ---@param suite table
    ---@param repeat_index integer
    ---@param repeat_count integer
    function handler.baseSuiteStart(suite, repeat_index, repeat_count)
        local first, second = base_suite_start(suite)
        run.repeat_index = repeat_index
        run.repeat_count = repeat_count
        append_line(run, ('RUN %d/%d'):format(repeat_index, repeat_count))
        publish(publisher, EventType.REPEAT_STARTED, {
            repeat_index=repeat_index,
            repeat_count=repeat_count,
        })
        return first, second
    end

    ---Records completion of one Busted repeat.
    ---@param suite table
    function handler.baseSuiteEnd(suite)
        local first, second = base_suite_end(suite)
        append_line(run, ('RUN_END %d/%d'):format(
            run.repeat_index, run.repeat_count))
        publish(publisher, EventType.REPEAT_FINISHED, {
            repeat_index=run.repeat_index,
            counts=run.last_repeat_counts or
                {successes=0, failures=0, errors=0, pending=0},
        })
        return first, second
    end

    ---Records the currently executing ordinary Busted test.
    ---@param element table
    ---@param parent table
    function handler.baseTestStart(element, parent)
        local first, second = base_test_start(element, parent)
        run.current_test = handler.getFullName(element)
        run.current_test_started_ms = publisher_time(publisher)
        append_line(run, 'START ' .. run.current_test)
        publish(publisher, EventType.TEST_STARTED, {
            name=run.current_test,
            source_identity=element.source or element.short_src,
        })
        return first, second
    end

    ---Records the ordinary Busted result and per-repeat plus total counts.
    ---@param element table
    ---@param parent table
    ---@param status string
    ---@param trace any
    function handler.baseTestEnd(element, parent, status, trace)
        local first, second = base_test_end(element, parent, status, trace)
        local count_key = ({
            success='successes',
            failure='failures',
            error='errors',
            pending='pending',
        })[status]
        if count_key then
            run.counts[count_key] = run.counts[count_key] + 1
            run.totals[count_key] = run.totals[count_key] + 1
        end
        run.last_repeat_counts = {
            successes=handler.successesCount,
            failures=handler.failuresCount,
            errors=handler.errorsCount,
            pending=handler.pendingsCount,
        }
        append_line(run, status:upper() .. ' ' .. handler.getFullName(element))
        publish(publisher, EventType.TEST_FINISHED, {
            name=handler.getFullName(element),
            status=status,
            duration_ms=math.max(0,
                publisher_time(publisher) -
                    (run.current_test_started_ms or 0)),
        })
        run.current_test = nil
        run.current_test_started_ms = nil
        return first, second
    end

    ---Records a Luassert-classified Busted test failure.
    ---@param element table
    ---@param parent table
    ---@param message any
    ---@param trace any
    function handler.baseTestFailure(element, parent, message, trace)
        local first, second = base_test_failure(
            element, parent, message, trace)
        record_problem(run, 'failure', handler, element, message, trace)
        publish(publisher, EventType.PROBLEM_RECORDED, {
            kind='failure',
            name=handler.getFullName(element),
            message=tostring(message),
            trace=trace_text(trace),
        })
        return first, second
    end

    ---Records a raw error raised by a Busted test.
    ---@param element table
    ---@param parent table
    ---@param message any
    ---@param trace any
    function handler.baseTestError(element, parent, message, trace)
        local first, second = base_test_error(element, parent, message, trace)
        record_problem(run, 'error', handler, element, message, trace)
        publish(publisher, EventType.PROBLEM_RECORDED, {
            kind='error',
            name=handler.getFullName(element),
            message=tostring(message),
            trace=trace_text(trace),
        })
        return first, second
    end

    ---Records a file, hook, or other non-test Busted error.
    ---@param element table
    ---@param parent table|nil
    ---@param message any
    ---@param trace any
    function handler.baseError(element, parent, message, trace)
        local first, second = base_error(element, parent, message, trace)
        if element.descriptor ~= 'it' then
            run.counts.errors = run.counts.errors + 1
            run.totals.errors = run.totals.errors + 1
            record_problem(run, 'error', handler, element, message, trace)
            publish(publisher, EventType.PROBLEM_RECORDED, {
                kind='error',
                name=handler.getFullName(element),
                message=tostring(message),
                trace=trace_text(trace),
            })
        end
        return first, second
    end

    handler:subscribe{language='en', suppressPending=false}
    return handler
end

return M
