-- Run cancellation, acknowledgement, and executor recovery orchestration.

local RunState = require('dwarfspec.protocol.enums.run_states')

local M = {}

---Creates recovery operations over explicit command and transport dependencies.
---@param dependencies table
---@return table
function M.new(dependencies)
    assert(type(dependencies) == 'table', 'run recovery dependencies are required')
    local builder = assert(dependencies.builder, 'recovery command builder is required')
    local client = assert(dependencies.client, 'recovery transport client is required')
    local failure = assert(dependencies.failure, 'recovery failure constructor is required')
    local kinds = assert(dependencies.failure_kinds, 'recovery failure kinds are required')
    local exits = assert(dependencies.exit_codes, 'recovery exit codes are required')
    local clean_message = assert(dependencies.clean_message, 'recovery error cleaner is required')
    local recovery = {}

    ---Appends recovery diagnostics without replacing the original runner failure.
    ---@param original_error table
    ---@param recovery_error string|nil
    ---@return table
    function recovery.preserve_error(original_error, recovery_error)
        if recovery_error then
            original_error.message = original_error.message ..
                '; recovery failed: ' .. recovery_error
        end
        return original_error
    end

    ---Attempts state-aware recovery without replacing the original failure.
    ---@param options table
    ---@param runner string
    ---@param run_id string
    ---@param owner_capability string|nil
    ---@param expected table|nil
    ---@param after_sequence integer
    ---@return table|nil, string|nil
    function recovery.after_failure(options, runner, run_id, owner_capability,
            expected, after_sequence)
        local invoked, result = pcall(client.invoke, options, runner,
            builder.recover(options, run_id, owner_capability, after_sequence))
        if not invoked then
            return nil, 'recovery bridge failed: ' .. clean_message(result)
        end
        if result.exit_code ~= 0 then
            if client.parse_transport_response then
                local parsed, transport, rejection = pcall(
                    client.parse_transport_response, result.lines,
                    expected or {run_id=run_id}, options.decode_json)
                if parsed and rejection then return nil, rejection.message end
            end
            return nil, 'recovery exited with ' .. result.exit_code
        end
        local parse_expected = {}
        for name, value in pairs(expected or {run_id=run_id}) do
            parse_expected[name] = value
        end
        parse_expected.after_sequence = after_sequence
        local ok, transport, rejection
        if client.parse_transport_response then
            ok, transport, rejection = pcall(client.parse_transport_response,
                result.lines, parse_expected, options.decode_json)
        else
            ok, transport = pcall(client.parse_transport, result.lines,
                parse_expected, options.decode_json)
        end
        if not ok then return nil, tostring(transport) end
        if rejection then return nil, rejection.message end
        local report = transport.snapshot
        if not report.terminal then return transport, 'recovery left the run nonterminal' end
        if report.state == RunState.ABORTED and not report.cleanup_confirmed then
            return transport, 'recovery abort did not confirm cleanup'
        end
        if report.state ~= RunState.CANCELLED and not report.cleanup_confirmed then
            return transport, 'recovery terminal cleanup was not confirmed'
        end
        return transport, nil
    end

    ---Acknowledges one persisted terminal generation.
    ---@param options table
    ---@param runner string
    ---@param run_id string
    ---@param generation integer
    ---@param owner_capability string
    ---@param expected table
    ---@param after_sequence integer
    function recovery.acknowledge(options, runner, run_id, generation,
            owner_capability, expected, after_sequence)
        local parse_expected = {}
        for name, value in pairs(expected) do parse_expected[name] = value end
        parse_expected.after_sequence = after_sequence
        client.transport(options, runner,
            builder.acknowledge(options, run_id, generation,
                owner_capability, after_sequence),
            parse_expected, 'acknowledgement')
    end

    ---Explicitly cancels a queued run or aborts an active run.
    ---@param options table
    ---@param runner string
    ---@param run_id string
    ---@return table
    function recovery.abort(options, runner, run_id)
        local ok, transport = pcall(client.transport, options, runner,
            builder.abort(options, run_id), {run_id=run_id, after_sequence=0},
            'abort')
        if not ok then
            local detail = type(transport) == 'table' and transport or
                failure(kinds.HOST, tostring(transport))
            return {exit_code=detail.exit_code, error=detail}
        end
        local report = transport.snapshot
        if report.state == RunState.CANCELLED then
            return {exit_code=exits[kinds.SUCCESS], report=report,
                events=transport.events}
        end
        if report.state ~= RunState.ABORTED or not report.cleanup_confirmed then
            return {exit_code=exits[kinds.TEST], report=report,
                error=failure(kinds.TEST, 'abort did not confirm cleanup')}
        end
        return {exit_code=exits[kinds.SUCCESS], report=report,
            events=transport.events}
    end

    ---Recovers one exact quarantined executor after clean-state verification.
    ---@param options table
    ---@param runner string
    ---@param run_id string
    ---@param generation integer
    ---@param reason string
    ---@return table
    function recovery.recover_executor(options, runner, run_id, generation, reason)
        local ok, transport = pcall(client.transport, options, runner,
            builder.recover_executor(options, run_id, generation, reason), {
                run_id=run_id, generation=generation, after_sequence=0,
            }, 'executor recovery')
        if not ok then
            local detail = type(transport) == 'table' and transport or
                failure(kinds.HOST, clean_message(transport))
            return {exit_code=detail.exit_code, error=detail}
        end
        if not transport.scheduler or transport.scheduler.quarantine.active then
            return {exit_code=exits[kinds.HOST],
                error=failure(kinds.HOST,
                    'DwarfSpec executor recovery did not clear quarantine')}
        end
        return {exit_code=exits[kinds.SUCCESS], report=transport.snapshot,
            scheduler=transport.scheduler}
    end

    return recovery
end

return M
