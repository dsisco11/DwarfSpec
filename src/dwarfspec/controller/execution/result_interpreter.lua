-- Stable controller result classification and persistence orchestration.

local project = require('dwarfspec.controller.discovery.project')
local result_store = require('dwarfspec.controller.result_store')
local ResultState = require('dwarfspec.protocol.enums.result_states')
local RunState = require('dwarfspec.protocol.enums.run_states')

local M = {}

---Creates a result interpreter with the runner failure contract.
---@param dependencies table
---@return table
function M.new(dependencies)
    assert(type(dependencies) == 'table', 'result interpreter dependencies are required')
    local kinds = assert(dependencies.failure_kinds, 'result failure kinds are required')
    local exit_codes = assert(dependencies.exit_codes, 'result exit codes are required')
    local interpreter = {}

    ---Resolves the configured latest-result path through result-store policy.
    ---@param project_root string
    ---@param result_path string|boolean|nil
    ---@param filesystem table|nil
    ---@return string
    function interpreter.resolve_path(project_root, result_path, filesystem)
        return result_store.resolve_path(project_root, result_path, filesystem)
    end

    ---Returns whether a native report has entered the executor.
    ---@param report table
    ---@return boolean
    function interpreter.entered_executor(report)
        return report.state ~= RunState.QUEUED and report.activated_at_ms ~= nil
    end

    ---Maps one classified failure to its stable invocation result state.
    ---@param runner_error table
    ---@param native_report table|nil
    ---@param interrupted boolean
    ---@return DwarfSpecResultState
    function interpreter.failure_state(runner_error, native_report, interrupted)
        if interrupted then return ResultState.INTERRUPTED end
        local mapping = {
            [kinds.USAGE]=ResultState.USAGE_ERROR,
            [kinds.DEPENDENCY]=ResultState.DEPENDENCY_ERROR,
            [kinds.CONNECTION]=ResultState.CONNECTION_ERROR,
            [kinds.QUEUE_TIMEOUT]=ResultState.QUEUE_TIMEOUT,
            [kinds.EXECUTOR_QUARANTINED]=ResultState.EXECUTOR_QUARANTINED,
            [kinds.TIMEOUT]=ResultState.TIMEOUT,
            [kinds.REGISTRATION]=ResultState.REGISTRATION_ERROR,
            [kinds.CANCELLED]=ResultState.CANCELLED,
        }
        if mapping[runner_error.kind] then return mapping[runner_error.kind] end
        if runner_error.kind == kinds.ABORTED and native_report and
                native_report.state == RunState.ABORTED then
            return ResultState.ABORTED
        end
        if runner_error.kind == kinds.TEST and native_report then
            if native_report.state == RunState.PASSED then return ResultState.FAILED end
            return native_report.state
        end
        return ResultState.HOST_ERROR
    end

    ---Classifies one terminal native report into the public runner contract.
    ---@param report table
    ---@return DwarfSpecRunnerFailureKind|nil, string|nil
    function interpreter.classify_native(report)
        if report.state == RunState.ABORTED then
            return kinds.ABORTED, 'DwarfSpec run was aborted'
        end
        if report.state == RunState.CANCELLED then
            return kinds.CANCELLED,
                'DwarfSpec run was cancelled before activation'
        end
        if report.state ~= RunState.PASSED then
            return kinds.TEST, 'DwarfSpec run finished with state ' ..
                tostring(report.state)
        end
        if not report.cleanup_confirmed then
            return kinds.TEST,
                'DwarfSpec run passed without confirmed cleanup'
        end
        return nil, nil
    end

    ---Constructs one persisted invocation document.
    ---@param options table
    ---@param native_report table|nil
    ---@param state DwarfSpecResultState
    ---@param terminal boolean
    ---@param exit_code integer|nil
    ---@param submitted_at string
    ---@param activated_at string|nil
    ---@param finished_at string|nil
    ---@param runner_error table|nil
    ---@param journal table[]|nil
    ---@return table
    function interpreter.build(options, native_report, state, terminal,
            exit_code, submitted_at, activated_at, finished_at, runner_error,
            journal)
        local identity = native_report and native_report.service_instance_id ~= nil
        return result_store.build({
            service_instance_id=identity and native_report.service_instance_id or nil,
            project_id=identity and native_report.project_id or nil,
            run_id=identity and native_report.run_id or nil,
            generation=identity and native_report.generation or nil,
            state=state,
            terminal=terminal,
            exit_code=exit_code,
            project_root=project.normalize(options.project_root),
            selection={identities=options.identities},
            submitted_at=submitted_at,
            activated_at=activated_at,
            finished_at=finished_at,
            queue_wait_ms=native_report and native_report.queue_wait_ms or nil,
            error=runner_error and {kind=runner_error.kind,
                message=runner_error.message} or nil,
            host_report=native_report and interpreter.entered_executor(native_report) and
                native_report or nil,
            events=journal or {},
        })
    end

    ---Writes one result document through the existing safe-replacement authority.
    ---@param options table
    ---@param result table
    function interpreter.persist(options, result)
        if not options.result_path then return end
        local store = options.result_store or result_store
        store.write(options.result_path, result, {
            filesystem=options.filesystem,
            open_file=options.open_result_file,
            remove_file=options.remove_result_file,
            replace_file=options.replace_result_file,
            encode=options.encode_result,
        })
    end

    ---Returns the successful or failed native terminal exit code.
    ---@param report table
    ---@return integer
    function interpreter.native_exit_code(report)
        return report.state == RunState.PASSED and exit_codes[kinds.SUCCESS] or
            exit_codes[kinds.TEST]
    end

    interpreter.states = ResultState
    return interpreter
end

return M
