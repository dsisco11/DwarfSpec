-- Executes one validated command lifecycle with a single shared deadline.

local CleanupLifetime = require('dwarfspec.protocol.enums.cleanup_lifetimes')
local CommandFailureStage = require(
    'dwarfspec.protocol.enums.command_failure_stages')
local CommandKind = require('dwarfspec.protocol.enums.command_kinds')
local Context = require('dwarfspec.driver.command.context')
local Deadline = require('dwarfspec.driver.command.deadline')
local Diagnostics = require('dwarfspec.driver.command.diagnostics')
local IntrinsicKind = require(
    'dwarfspec.protocol.enums.intrinsic_verification_kinds')
local Outcomes = require('dwarfspec.driver.command.outcomes')
local RetryPolicy = require(
    'dwarfspec.protocol.enums.execution_retry_policies')

---@class dwarfspec.CommandRunner
---@field private _registry dwarfspec.CommandRegistry
---@field private _resource_index dwarfspec.ResourceDependencyIndex
---@field private _cleanup_service dwarfspec.CleanupRegistrationService
---@field private _dependencies table
---@field private _default_timeout_ms integer
---@field private _next_invocation_ordinal integer
local Runner = {}
Runner.__index = Runner

---@class dwarfspec.driver.command.RunnerInternals
local Internals = {}
Internals.diagnostics = Diagnostics.new()

---Validates one injected runner callback.
---@param dependencies table
---@param name string
---@return function
function Internals.callback(dependencies, name)
    local callback = dependencies[name]
    assert(type(callback) == 'function',
        'command runner requires ' .. name .. ' callback')
    return callback
end

---Creates a bounded error message without allowing diagnostics to throw.
---@param value any
---@return string
function Internals.error_text(value)
    local ok, text = pcall(tostring, value)
    if not ok then return '<unprintable command failure>' end
    return Internals.diagnostics:sanitize(text, 'command failure')
end

---Calls a lifecycle callback and retains its traceback as an ordinary failure.
---@param callback function
---@param ... any
---@return boolean, any
function Internals.call(callback, ...)
    return xpcall(function(...) return callback(...) end, debug.traceback, ...)
end

---Requires one explicit gate result supported by the current lifecycle stage.
---@param value any
---@param label string
---@param allow_effect_absent boolean|nil
---@return table
function Internals.gate(value, label, allow_effect_absent)
    local succeeded, validated = pcall(Outcomes.validate_gate, value,
        allow_effect_absent)
    assert(succeeded, label .. ' returned an invalid gate result: ' ..
        Internals.error_text(validated))
    return validated
end

---Returns whether a definition is observation-only.
---@param definition dwarfspec.CommandDefinition
---@return boolean
function Internals.read_only(definition)
    return definition.kind == CommandKind.QUERY or
        definition.kind == CommandKind.ASSERTION
end

---Creates the immutable identity supplied to callback contexts.
---@param runner dwarfspec.CommandRunner
---@param owner table
---@return table
function Internals.identity(runner, owner)
    runner._next_invocation_ordinal = runner._next_invocation_ordinal + 1
    local id = owner.service_run_id .. ':command:' ..
        tostring(runner._next_invocation_ordinal)
    return {invocation_id=id, root_invocation_id=id,
        owner_scope=owner.owner_scope, service_run_id=owner.service_run_id,
        suite_execution_id=owner.suite_execution_id,
        test_attempt_id=owner.test_attempt_id}
end

---Creates a callback context for the runner's current lifecycle stage.
---@param runner dwarfspec.CommandRunner
---@param identity table
---@param stage fun(): string
---@param read_only boolean|nil
---@param privileged boolean
---@param mutation_lease any
---@return table
function Internals.context(runner, identity, stage, read_only, privileged,
        mutation_lease)
    local options = {dependencies=runner._dependencies, identity=identity,
        stage=stage(), guard=Context.StageGuard.new(stage)}
    if read_only then return Context.new_read(options) end
    if not privileged then return Context.new_execution(options) end
    return Context.new_privileged_execution(options,
        Context.CleanupRegistrationCapability.new(function(registration)
            registration.mutation_lease = mutation_lease
            registration.command_invocation_id = identity.invocation_id
            return runner._cleanup_service:register(registration)
        end, options.guard))
end

---Waits once while preserving the single deadline and cancellation boundary.
---@param runner dwarfspec.CommandRunner
---@param deadline dwarfspec.CommandDeadline
---@return boolean, string|nil
function Internals.wait(runner, deadline)
    local cancelled, reason = runner._dependencies.cancellation()
    if cancelled then return false, 'cancelled: ' .. tostring(reason) end
    local remaining = deadline:remaining_ms()
    if remaining == 0 then return false, 'command deadline expired' end
    runner._dependencies.wait(remaining)
    if deadline:remaining_ms() >= remaining then
        return false, 'command scheduler did not advance time'
    end
    return true
end

---Polls an explicit read-only gate under the inherited deadline.
---@param runner dwarfspec.CommandRunner
---@param deadline dwarfspec.CommandDeadline
---@param stage fun(): string
---@param invoke function
---@param allow_effect_absent boolean|nil
---@param retry_errors boolean|nil
---@return boolean, table|string, table|nil
function Internals.poll(runner, deadline, stage, invoke, allow_effect_absent,
        retry_errors)
    local latest
    while deadline:remaining_ms() > 0 do
        local cancelled, reason = runner._dependencies.cancellation()
        if cancelled then return false, 'cancelled: ' .. tostring(reason), latest end
        local ok, result = Internals.call(invoke)
        if not ok then
            local message = Internals.error_text(result)
            if not retry_errors then return false, message, latest end
            latest = {message=message}
            local waited, failure = Internals.wait(runner, deadline)
            if not waited then return false, failure, latest end
        else
        local gate = Internals.gate(result, stage() .. ' callback',
            allow_effect_absent)
        if gate.kind == 'ready' then return true, gate, latest end
        if gate.kind == 'fatal' then return false, gate.message, gate.evidence end
        if Outcomes.is_effect_absent(gate) then return true, gate, latest end
        latest = {message=gate.message, evidence=gate.evidence}
        local waited, failure = Internals.wait(runner, deadline)
        if not waited then return false, failure, latest end
        end
    end
    return false, 'command deadline expired', latest
end

---Selects the newest bounded gate evidence without erasing earlier evidence.
---@param result table|string
---@param latest table|nil
---@param previous table|nil
---@return table|nil
function Internals.latest_gate_evidence(result, latest, previous)
    if type(result) == 'table' and result.evidence ~= nil then
        return result.evidence
    end
    if latest ~= nil then return latest end
    return previous
end

---Copies validated immutable outcome data into mutable-free plain transport data.
---@param value any
---@return any
function Internals.detach_outcome_data(value)
    if type(value) ~= 'table' then return value end
    local copy = {}
    for key, entry in pairs(value) do
        copy[Internals.detach_outcome_data(key)] =
            Internals.detach_outcome_data(entry)
    end
    return copy
end

---Registers cleanup before any later fallible lifecycle work.
---@param runner dwarfspec.CommandRunner
---@param definition table
---@param identity table
---@param owner table
---@param plan table
---@param outcome table
---@param mutation_lease any
---@return table|nil
function Internals.register_cleanup(runner, definition, identity, owner, plan,
        outcome, mutation_lease)
    if outcome.effect_receipt == nil then return nil end
    assert(definition.cleanup ~= nil,
        'command without cleanup policy returned an effect receipt')
    local bindings = definition.cleanup.resources and
        definition.cleanup.resources(outcome.effect_receipt) or {}
    return runner._cleanup_service:register({owner=owner,
        command_invocation_id=identity.invocation_id,
        mutation_lease=mutation_lease, label=definition.name,
        lifetime=definition.cleanup.lifetime,
        receipt=Internals.detach_outcome_data(outcome.effect_receipt),
        plan=plan, bindings=bindings, restore=definition.cleanup.restore,
        verify=definition.cleanup.verify,
        cleanup_timeout_ms=runner._dependencies.cleanup_timeout_ms,
        wait=runner._dependencies.wait,
        new_cancellation=runner._dependencies.new_cancellation,
        invoke_readonly=runner._dependencies.invoke_readonly,
        record_diagnostic=runner._dependencies.record_diagnostic,
        assert_executable=runner._dependencies.assert_cleanup_executable})
end

---Quarantines an adapter result whose effect cannot be established safely.
---@param runner dwarfspec.CommandRunner
---@param identity table
---@param owner table
---@param stage string
---@param failure any
---@param plan table
---@return string
function Internals.quarantine_ambiguous(runner, identity, owner, stage, failure,
        plan)
    local message = Internals.error_text(failure)
    local quarantined, quarantine_failure = Internals.call(function()
        assert(type(runner._cleanup_service.quarantineAmbiguousEffect) ==
            'function', 'cleanup service cannot quarantine ambiguous effects')
        runner._cleanup_service:quarantineAmbiguousEffect(
            identity.invocation_id, owner, {stage=stage,
                failure=message, plan=plan})
    end)
    if not quarantined then
        message = message .. '\nambiguous effect quarantine: ' ..
            Internals.error_text(quarantine_failure)
    end
    return message
end

---Formats detached bounded diagnostic data deterministically for one error.
---@param evidence any
---@return string
function Internals.evidence_text(evidence)
    if evidence == nil then return '<none>' end
    local function format(value)
        local value_type = type(value)
        if value_type == 'string' then return string.format('%q', value) end
        if value_type ~= 'table' then return tostring(value) end
        local keys = {}
        for key in pairs(value) do keys[#keys + 1] = key end
        table.sort(keys, function(left, right) return tostring(left) < tostring(right) end)
        local entries = {}
        for _, key in ipairs(keys) do
            entries[#entries + 1] = tostring(key) .. '=' .. format(value[key])
        end
        return '{' .. table.concat(entries, ', ') .. '}'
    end
    local succeeded, text = pcall(format, evidence)
    if not succeeded then return '<unprintable evidence>' end
    return Internals.error_text(text)
end

---Appends one stage-attributed finalization failure without replacement.
---@param failure string|nil
---@param stage string
---@param value any
---@param evidence any
---@return string
function Internals.append_failure(failure, stage, value, evidence)
    local message = Internals.stage_failure(stage, value, evidence)
    return failure and failure .. '\n' .. message or message
end

---Executes a still-pending command-lifetime transaction and composes failure.
---@param definition table
---@param transaction any
---@param failure string|nil
---@param evidence any
---@return string|nil
function Internals.finish_command_cleanup(definition, transaction, failure,
        evidence)
    local succeeded, cleanup_failure = Internals.call(function()
        if transaction == nil or definition.cleanup == nil or
                definition.cleanup.lifetime ~= CleanupLifetime.COMMAND or
                not transaction:isPending() then
            return
        end
        transaction:execute('command lifecycle finalization')
    end)
    if succeeded then return failure end
    return Internals.append_failure(failure, 'command_cleanup', cleanup_failure,
        evidence)
end

---Publishes optional bounded lifecycle evidence through the host event seam.
---@param runner dwarfspec.CommandRunner
---@param event_type string
---@param payload table
function Internals.publish(runner, event_type, payload)
    local publish = runner._dependencies.publish
    if publish == nil then return end
    publish(event_type, Internals.diagnostics:sanitize(payload,
        'command lifecycle event'))
end

---Validates the trailing invocation options without reserving domain fields.
---@param options any
---@return table
function Internals.options(options)
    options = options or {}
    assert(type(options) == 'table', 'command options must be a table')
    for name in pairs(options) do
        assert(name == 'timeout_ms' or name == 'description' or name == 'verify',
            'unsupported command option: ' .. tostring(name))
    end
    if options.timeout_ms ~= nil then
        assert(type(options.timeout_ms) == 'number' and
            options.timeout_ms >= 1 and options.timeout_ms % 1 == 0 and
            options.timeout_ms < math.huge,
            'command timeout_ms must be a positive finite integer')
    end
    assert(options.description == nil or type(options.description) == 'string',
        'command description must be a string')
    assert(options.verify == nil or type(options.verify) == 'function',
        'command verify option must be callable')
    return options
end

---Composes a terminal gate failure with its last bounded pending observation.
---@param failure any
---@param latest table|nil
---@return string
function Internals.gate_failure(failure, latest)
    local message = tostring(failure)
    if latest == nil then return message end
    return message .. '; last pending: ' .. tostring(latest.message)
end

---Attributes one bounded lifecycle failure to its exact current stage.
---@param stage string
---@param failure any
---@param evidence any
---@return string
function Internals.stage_failure(stage, failure, evidence)
    return stage .. ': ' .. Internals.error_text(failure) ..
        '; latest evidence: ' .. Internals.evidence_text(evidence)
end

---Creates one command runner with all host-owned mutation seams injected.
---@param options table
---@return dwarfspec.CommandRunner
function Runner.new(options)
    assert(type(options) == 'table', 'command runner options are required')
    assert(type(options.registry) == 'table' and type(options.registry.get) == 'function',
        'command runner requires a command registry')
    assert(type(options.resource_index) == 'table' and
        type(options.resource_index.validate_plan) == 'function',
        'command runner requires a resource dependency index')
    assert(type(options.cleanup_service) == 'table' and
        type(options.cleanup_service.begin_mutation) == 'function',
        'command runner requires a cleanup registration service')
    assert(type(options.dependencies) == 'table',
        'command runner requires dependencies')
    local dependencies = options.dependencies
    for _, name in ipairs({'now_ms', 'wait', 'cancellation', 'owner',
            'cleanup_checkpoint', 'new_cancellation', 'invoke_readonly',
            'record_diagnostic', 'assert_cleanup_executable'}) do
        Internals.callback(dependencies, name)
    end
    assert(type(options.default_timeout_ms) == 'number' and
        options.default_timeout_ms >= 1 and options.default_timeout_ms % 1 == 0,
        'command runner requires a positive default timeout')
    assert(options.refresh_retained_subjects == nil or
        type(options.refresh_retained_subjects) == 'function',
        'command runner retained-subject refresh must be callable')
    return setmetatable({_registry=options.registry,
        _resource_index=options.resource_index,
        _cleanup_service=options.cleanup_service, _dependencies=dependencies,
        _default_timeout_ms=options.default_timeout_ms,
        _next_invocation_ordinal=0,
        _refresh_retained_subjects=options.refresh_retained_subjects or
            function() end}, Runner)
end

---Installs the run-local retained-subject refresh composition seam.
---@param callback fun(identity: table)
function Runner:setRefreshRetainedSubjects(callback)
    assert(type(callback) == 'function',
        'retained-subject refresh callback must be callable')
    self._refresh_retained_subjects = callback
end

---Runs one registered command and returns only its original public result.
---@param name string
---@param arguments table
---@param options? table
---@return any
function Runner:invoke(name, arguments, options)
    assert(type(name) == 'string' and name ~= '',
        'command name must be a nonempty string')
    assert(type(arguments) == 'table', 'command arguments must be a table')
    options = Internals.options(options)
    local definition = assert(self._registry:get(name),
        'unknown command ' .. name)
    local normalized, normalized_or_failure = Internals.call(function()
        local request = definition.normalize(arguments)
        request = Internals.diagnostics:sanitize(request,
            'normalized command request')
        local operation_key
        if definition.execution_retry_policy == RetryPolicy.EXPLICIT_RETRY_SAFE then
            operation_key = definition.operation_key(request)
            assert(type(operation_key) == 'string' and operation_key ~= '' and
                #operation_key <= 128,
                'command operation key must be a bounded nonempty string')
        end
        return {request=request, operation_key=operation_key}
    end)
    if not normalized then
        error(Internals.stage_failure(CommandFailureStage.NORMALIZATION,
            normalized_or_failure, nil), 0)
    end
    local request = normalized_or_failure.request
    local operation_key = normalized_or_failure.operation_key
    local timeout_ms = options.timeout_ms or definition.default_timeout_ms or
        self._default_timeout_ms
    local deadline = Deadline.new(self._dependencies.now_ms, timeout_ms)
    local owner = self._dependencies.owner()
    local identity = Internals.identity(self, owner)
    local started_at_ms = self._dependencies.now_ms()
    local start_published, start_publish_failure = Internals.call(function()
        Internals.publish(self, 'command.started', {name=name,
            subject_identity=identity.target_identity or '<none>',
            safe_arguments=request})
    end)
    if not start_published then
        error(Internals.stage_failure(CommandFailureStage.RESULT_PROJECTION,
            start_publish_failure, nil), 0)
    end
    local stage = 'preflight'
    local latest_evidence
    local transaction
    local mutation_lease
    local completed, result = xpcall(function()
    identity.cleanup_checkpoint = self._dependencies.cleanup_checkpoint()
    local function current_stage() return stage end
    local context = Internals.context(self, identity, current_stage, true,
        false, nil)
    local ready_ok, ready_or_failure, evidence = Internals.poll(self, deadline,
        current_stage, function() return definition.preflight(context, request) end)
    latest_evidence = Internals.latest_gate_evidence(ready_or_failure, evidence,
        latest_evidence)
    if not ready_ok then
        error(Internals.gate_failure(ready_or_failure, evidence), 2)
    end
    local ready = ready_or_failure.value
    local final_ready_ok, final_ready_or_failure, final_evidence = Internals.poll(self,
        deadline, current_stage, function()
            return definition.preflight(context, request)
        end)
    latest_evidence = Internals.latest_gate_evidence(final_ready_or_failure,
        final_evidence, latest_evidence)
    if not final_ready_ok then
        error(Internals.gate_failure(final_ready_or_failure, final_evidence), 2)
    end
    ready = final_ready_or_failure.value
    if type(ready) == 'table' and type(ready.target_identity) == 'string' and
            ready.target_identity ~= '' then
        identity.target_identity = ready.target_identity
    end
    stage = 'claim_planning'
    local plan_entries = definition.claims and
        definition.claims(context, request, ready) or {}
    local plan = self._resource_index:validate_plan(owner, identity.invocation_id,
        definition.cleanup and definition.cleanup.lifetime or CleanupLifetime.OWNER,
        plan_entries, operation_key,
        definition.cleanup and definition.cleanup.allow_cross_owner_consumption and
            self._resource_index:consumption_authorization(definition) or nil)
    stage = 'execution'
    if deadline:remaining_ms() == 0 then error('command deadline expired', 2) end
    if not Internals.read_only(definition) then
        identity.attempt_cleanup_checkpoint = self._dependencies.cleanup_checkpoint()
        mutation_lease = self._cleanup_service:begin_mutation(identity.invocation_id)
        context = Internals.context(self, identity, current_stage, false,
            false, mutation_lease)
    end
    local outcome
    if Internals.read_only(definition) then
        local observed, gate_or_failure, primary_evidence = Internals.poll(
            self, deadline, current_stage, function()
                return definition.execute(context, request, ready)
            end)
        latest_evidence = Internals.latest_gate_evidence(gate_or_failure,
            primary_evidence, latest_evidence)
        if not observed then
            error(Internals.gate_failure(gate_or_failure, primary_evidence), 2)
        end
        outcome = {kind='executed', public_result=gate_or_failure.value,
            receipt=gate_or_failure, intrinsic_evidence=gate_or_failure.evidence}
    else
        local execute_ok
        execute_ok, outcome = Internals.call(definition.execute, context,
            request, ready)
        if not execute_ok then
            error(Internals.quarantine_ambiguous(self, identity, owner, stage,
                outcome, plan), 2)
        end
        local valid, validated = Internals.call(Outcomes.validate_execution,
            outcome, definition)
        if not valid then
            error(Internals.quarantine_ambiguous(self, identity, owner, stage,
                validated, plan), 2)
        end
        outcome = validated
        latest_evidence = outcome.evidence or latest_evidence
    end
    if outcome.effect_receipt ~= nil then
        stage = 'cleanup_registration'
        local registered, registered_or_error = Internals.call(
            Internals.register_cleanup, self, definition, identity, owner, plan,
            outcome, mutation_lease)
        if not registered then error(Internals.error_text(registered_or_error), 2) end
        transaction = registered_or_error
        stage = 'execution'
    end
    if not Internals.read_only(definition) and
            not deadline:check_execution_return() then
        error('command deadline expired during execution', 2)
    end
    if outcome.kind == 'retry' then
        error('explicit retry-safe execution is implemented in the next delivery step',
            2)
    end
    if outcome.kind == 'failed' then
        error(outcome.message, 2)
    end
    stage = 'intrinsic_verification'
    local latest_intrinsic_evidence
    if definition.intrinsic_verification == IntrinsicKind.CALLBACK then
        context = Internals.context(self, identity, current_stage, true,
            false, nil)
        local verified, result, latest = Internals.poll(self, deadline, current_stage,
            function() return definition.verify(context, request, outcome.receipt) end,
            true)
        latest_intrinsic_evidence = type(result) == 'table' and
            result.evidence or latest
        latest_evidence = latest_intrinsic_evidence or latest_evidence
        if not verified then
            error(Internals.gate_failure(result, latest), 2)
        end
        if Outcomes.is_effect_absent(result) then
            assert(transaction ~= nil, 'effect_absent requires registered cleanup')
            self._cleanup_service:abandonSelfRolledBack(transaction:transaction_id(),
                mutation_lease, result)
            error(result.message, 2)
        end
    elseif definition.intrinsic_verification ==
            IntrinsicKind.PRIMARY_OBSERVATION then
        latest_intrinsic_evidence = outcome.intrinsic_evidence or
            {kind='primary_observation'}
        latest_evidence = latest_intrinsic_evidence
    elseif definition.intrinsic_verification ==
            IntrinsicKind.EXECUTION_RECEIPT then
        assert(outcome.receipt ~= nil,
            'execution_receipt verification requires an immutable receipt')
        latest_intrinsic_evidence = outcome.receipt
        latest_evidence = latest_intrinsic_evidence
    else
        error('command has an unsupported intrinsic verification policy', 2)
    end
    if options.verify ~= nil then
        stage = 'caller_verification'
        local started_at_ms = deadline:expires_at_ms() - timeout_ms
        local verified, result, latest = Internals.poll(self, deadline, current_stage,
            function()
                local observation = Internals.diagnostics:sanitize({name=name,
                    kind=definition.kind, public_result=outcome.public_result,
                    receipt=outcome.receipt, attempt_count=1,
                    stable_target_identity=identity.target_identity,
                    elapsed_ms=self._dependencies.now_ms() - started_at_ms,
                    remaining_ms=deadline:remaining_ms(),
                    latest_intrinsic_evidence=latest_intrinsic_evidence},
                    'caller verification observation')
                local accepted = options.verify(observation)
                return accepted and Outcomes.ready(true) or
                    Outcomes.pending('caller verification is not yet satisfied')
            end, false, true)
        latest_evidence = Internals.latest_gate_evidence(result, latest,
            latest_evidence)
        if not verified then
            error(Internals.gate_failure(result, latest), 2)
        end
    end
    return outcome.public_result
    end, debug.traceback)

    local terminal_stage = completed and 'completed' or stage
    local failure
    if not completed then
        failure = Internals.stage_failure(stage, result, latest_evidence)
    end
    if mutation_lease then
        local released, release_failure = Internals.call(function()
            mutation_lease:release()
        end)
        mutation_lease = nil
        if not released then
            failure = Internals.append_failure(failure, 'mutation_lease_release',
                release_failure, latest_evidence)
            if completed then terminal_stage = 'mutation_lease_release' end
            completed = false
        end
    end

    local pending = {}
    if transaction ~= nil then pending[1] = transaction end
    if type(self._cleanup_service.pendingCommandTransactions) == 'function' then
        local discovered, merged_or_failure = Internals.call(function()
            local candidates = self._cleanup_service:pendingCommandTransactions(
                identity.invocation_id)
            assert(type(candidates) == 'table',
                'command cleanup discovery must return a table')
            local count, greatest_index = 0, 0
            for index in pairs(candidates) do
                assert(type(index) == 'number' and index >= 1 and
                    index % 1 == 0,
                    'command cleanup discovery must return an array')
                count = count + 1
                greatest_index = math.max(greatest_index, index)
            end
            assert(count == greatest_index,
                'command cleanup discovery must return a contiguous array')
            local merged = {}
            for _, known in ipairs(pending) do merged[#merged + 1] = known end
            for _, candidate in ipairs(candidates) do
                local duplicate = false
                for _, known in ipairs(merged) do
                    if known == candidate then duplicate = true break end
                end
                if not duplicate then merged[#merged + 1] = candidate end
            end
            return merged
        end)
        if not discovered then
            failure = Internals.append_failure(failure,
                'command_cleanup_discovery', merged_or_failure, latest_evidence)
            if completed then terminal_stage = 'command_cleanup_discovery' end
            completed = false
        else
            pending = merged_or_failure
        end
    end
    for _, candidate in ipairs(pending) do
        local prior_failure = failure
        failure = Internals.finish_command_cleanup(definition, candidate, failure,
            latest_evidence)
        if prior_failure == nil and failure ~= nil then
            terminal_stage = 'command_cleanup'
        end
    end
    completed = failure == nil

    if completed then
        stage = 'retained_subject_refresh'
        local refreshed, refresh_failure = Internals.call(
            self._refresh_retained_subjects, identity)
        if not refreshed then
            completed = false
            terminal_stage = stage
            failure = Internals.stage_failure(stage, refresh_failure,
                latest_evidence)
        end
    end
    local terminal_published, terminal_publish_failure = Internals.call(function()
        Internals.publish(self, 'command.finished', {name=name,
            status=completed and 'success' or 'failure',
            stage=completed and 'completed' or terminal_stage,
            duration_ms=math.max(0, math.floor(self._dependencies.now_ms() -
                started_at_ms))})
    end)
    if not terminal_published then
        failure = Internals.append_failure(failure,
            CommandFailureStage.RESULT_PROJECTION, terminal_publish_failure,
            latest_evidence)
        completed = false
    end
    if not completed then error(failure, 0) end
    return result
end

return Runner
