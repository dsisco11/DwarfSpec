-- Queued and active run polling with independent timeout budgets.

local RunState = require('dwarfspec.protocol.enums.run_states')

local M = {}

---Creates a run poller over an explicit transport dependency.
---@param dependencies table
---@return table
function M.new(dependencies)
    assert(type(dependencies) == 'table', 'run poller dependencies are required')
    local builder = assert(dependencies.builder, 'poll command builder is required')
    local client = assert(dependencies.client, 'poll transport client is required')
    local fail = assert(dependencies.fail, 'poll failure callback is required')
    local kinds = assert(dependencies.failure_kinds, 'poll failure kinds are required')
    local clean_message = assert(dependencies.clean_message, 'poll error cleaner is required')
    local format_events = assert(dependencies.format_events,
        'poll event formatter is required')
    local poller = {}

    ---Consumes one validated transport response in cursor order.
    ---@param scope table
    ---@param transport table
    ---@param persist boolean
    ---@param render boolean|nil
    ---@return table
    function poller.consume(scope, transport, persist, render)
        for _, event in ipairs(transport.events) do
            table.insert(scope.journal, event)
        end
        local report = transport.snapshot
        local execution_started_at = scope.execution_started_at
        if scope.activated_at() == nil and scope.entered_executor(report) then
            execution_started_at = scope.activate()
        end
        if scope.observe then
            scope.observe(report, transport.last_sequence, execution_started_at)
        end
        if render ~= false then
            local formatted, lines = pcall(format_events,
                transport.events, {
                    error_format=scope.error_format,
                    project_root=scope.options.project_root,
                    diagnostic_formatter=scope.options.diagnostic_formatter,
                })
            if not formatted then
                scope.formatting_failed()
                fail(kinds.HOST, 'DwarfSpec diagnostic formatting failed: ' ..
                    clean_message(lines))
            end
            for _, line in ipairs(lines) do scope.emit(line) end
        end
        if persist then scope.persist(report) end
        return {report=report, cursor=transport.last_sequence,
            execution_started_at=execution_started_at}
    end

    ---Polls until a terminal report while maintaining cursor and lease ownership.
    ---@param scope table
    ---@return table
    function poller.until_terminal(scope)
        local report = scope.report
        local cursor = scope.cursor
        local execution_started_at = scope.execution_started_at
        while not report.terminal do
            local current_time = scope.now()
            if report.state == RunState.QUEUED and
                    scope.options.queue_timeout_seconds ~= nil and
                    current_time - scope.queue_started_at >=
                        scope.options.queue_timeout_seconds then
                fail(kinds.QUEUE_TIMEOUT,
                    ('DwarfSpec queue wait timed out after %s seconds')
                        :format(scope.options.queue_timeout_seconds))
            end
            if execution_started_at ~= nil and
                    current_time - execution_started_at >=
                        scope.options.timeout_seconds then
                fail(kinds.TIMEOUT,
                    ('DwarfSpec execution timed out after %s seconds')
                        :format(scope.options.timeout_seconds))
            end
            scope.sleep(scope.options.poll_interval_ms / 1000)
            local expected = scope.expectation(cursor)
            local transport = client.transport(scope.options, scope.runner,
                builder.poll(scope.options, scope.run_id,
                    scope.owner_capability, cursor), expected, 'status')
            scope.execution_started_at = execution_started_at
            local consumed = poller.consume(scope, transport, true)
            report = consumed.report
            cursor = consumed.cursor
            execution_started_at = consumed.execution_started_at
        end
        return {report=report, cursor=cursor,
            execution_started_at=execution_started_at}
    end

    return poller
end

return M
