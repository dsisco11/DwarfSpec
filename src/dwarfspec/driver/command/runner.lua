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
    if #text > 480 then text = text:sub(1, 477) .. '...' end
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
        outcome, mutation_lease, lifetime)
    if outcome.effect_receipt == nil then return nil end
    assert(definition.cleanup ~= nil,
        'command without cleanup policy returned an effect receipt')
    local bindings = definition.cleanup.resources and
        definition.cleanup.resources(outcome.effect_receipt) or {}
    return runner._cleanup_service:register({owner=owner,
        command_invocation_id=identity.invocation_id,
        mutation_lease=mutation_lease, label=definition.name,
        lifetime=lifetime or definition.cleanup.lifetime,
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

---Returns pending command transactions created by the current invocation.
---@param runner dwarfspec.CommandRunner
---@param invocation_id string
---@param checkpoint integer
---@return table[]
function Internals.pending_command_transactions(runner, invocation_id, checkpoint)
    if type(runner._cleanup_service.pendingCommandTransactionsSince) ==
            'function' then
        return runner._cleanup_service:pendingCommandTransactionsSince(
            invocation_id, checkpoint)
    end
    if type(runner._cleanup_service.pendingCommandTransactions) ~= 'function' then
        return {}
    end
    local transactions = runner._cleanup_service:pendingCommandTransactions(
        invocation_id)
    assert(type(transactions) == 'table',
        'command cleanup discovery must return a table')
    return transactions
end

---Executes and verifies every effect reported by one retry attempt.
---@param runner dwarfspec.CommandRunner
---@param invocation_id string
---@param checkpoint integer
function Internals.finish_retry_cleanup(runner, invocation_id, checkpoint)
    if type(runner._cleanup_service.executeCommandTransactionsSince) ==
            'function' then
        local confirmed, failures =
            runner._cleanup_service:executeCommandTransactionsSince(
                invocation_id, checkpoint, 'execution retry')
        if not confirmed then
            local bounded = {}
            for index, failure in ipairs(failures) do
                bounded[index] = Internals.error_text(failure)
            end
            error('retry cleanup was not confirmed: ' ..
                table.concat(bounded, '; '), 2)
        end
        return
    end
    for _, transaction in ipairs(Internals.pending_command_transactions(runner,
            invocation_id, checkpoint)) do
        assert(transaction:isPending(),
            'retry cleanup discovery returned a nonpending transaction')
        transaction:execute('execution retry')
        assert(not transaction:isPending() and transaction:state() == 'complete',
            'retry cleanup was not confirmed')
    end
end

---Records one bounded retry attempt for terminal evidence and diagnostics.
---@param runner dwarfspec.CommandRunner
---@param attempts table[]
---@param receipts table[]
---@param attempt integer
---@param outcome table
---@return table
function Internals.record_retry(runner, attempts, receipts, attempt, outcome)
    assert(attempt <= 64, 'command retry attempt limit exceeded')
    local record = Internals.diagnostics:sanitize({attempt=attempt,
        kind=outcome.kind, reason=outcome.reason,
        attempt_receipt_present=outcome.attempt_receipt ~= nil,
        evidence=outcome.evidence,
        effect_reported=outcome.effect_receipt ~= nil},
        'command retry attempt')
    attempts[#attempts + 1] = record
    receipts[#receipts + 1] = {attempt=attempt,
        receipt=outcome.attempt_receipt}
    runner._dependencies.record_diagnostic('command.retry', record)
    return record
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

---Owns mutable state and stage transitions for one command invocation.
---@class dwarfspec.CommandInvocation
local Invocation = {}
Invocation.__index = Invocation

---Creates invocation-local state shared by the command lifecycle stages.
---@param runner dwarfspec.CommandRunner
---@param name string
---@param arguments table
---@param options table
---@return table
function Invocation.new(runner, name, arguments, options)
    return setmetatable({_runner=runner, _name=name, _arguments=arguments,
        _options=options, _definition=assert(runner._registry:get(name),
            'unknown command ' .. name), _stage='normalization',
        _latest_evidence=nil, _transaction=nil, _mutation_lease=nil,
        _attempt=1, _retry_attempts={}, _attempt_receipts={}}, Invocation)
end

---Returns the current lifecycle stage for command contexts and diagnostics.
---@return string
function Invocation:current_stage()
    return self._stage
end

---Normalizes input and establishes immutable invocation-wide dependencies.
function Invocation:normalize()
    local normalized, value = Internals.call(function()
        local request = self._definition.normalize(self._arguments)
        request = Internals.diagnostics:sanitize(request,
            'normalized command request')
        local operation_key
        if self._definition.execution_retry_policy ==
                RetryPolicy.EXPLICIT_RETRY_SAFE then
            operation_key = self._definition.operation_key(request)
            assert(type(operation_key) == 'string' and operation_key ~= '' and
                #operation_key <= 128,
                'command operation key must be a bounded nonempty string')
        end
        return {request=request, operation_key=operation_key}
    end)
    if not normalized then
        error(Internals.stage_failure(CommandFailureStage.NORMALIZATION,
            value, nil), 0)
    end
    self._request = value.request
    self._operation_key = value.operation_key
    self._timeout_ms = self._options.timeout_ms or
        self._definition.default_timeout_ms or self._runner._default_timeout_ms
    self._deadline = Deadline.new(self._runner._dependencies.now_ms,
        self._timeout_ms)
    self._deadline_started_at_ms = self._deadline:expires_at_ms() -
        self._timeout_ms
    self._owner = self._runner._dependencies.owner()
    self._identity = Internals.identity(self._runner, self._owner)
    self._started_at_ms = self._runner._dependencies.now_ms()
end

---Publishes the invocation start envelope before command execution begins.
function Invocation:publish_start()
    local published, failure = Internals.call(function()
        Internals.publish(self._runner, 'command.started', {name=self._name,
            subject_identity=self._identity.target_identity or '<none>',
            safe_arguments=self._request, operation_key=self._operation_key})
    end)
    if not published then
        error(Internals.stage_failure(CommandFailureStage.RESULT_PROJECTION,
            failure, nil), 0)
    end
end

---Runs initial and volatile preflight validation for the current attempt.
---@return any, table
function Invocation:run_preflight()
    self._stage = 'preflight'
    self._identity.attempt = self._attempt
    local context = Internals.context(self._runner, self._identity,
        function() return self:current_stage() end, true, false, nil)
    local ready
    for _ = 1, 2 do
        local accepted, result, evidence = Internals.poll(self._runner,
            self._deadline, function() return self:current_stage() end,
            function()
                return self._definition.preflight(context, self._request)
            end)
        self._latest_evidence = Internals.latest_gate_evidence(result, evidence,
            self._latest_evidence)
        if not accepted then
            error(Internals.gate_failure(result, evidence), 2)
        end
        ready = result.value
    end
    if type(ready) == 'table' and
            type(ready.target_identity) == 'string' and
            ready.target_identity ~= '' then
        self._identity.target_identity = ready.target_identity
    end
    return ready, context
end

---Projects and validates resource claims for the current attempt.
---@param ready any
---@param context table
---@return table, table|nil
function Invocation:plan_claims(ready, context)
    self._stage = 'claim_planning'
    local definition = self._definition
    local entries = definition.claims and
        definition.claims(context, self._request, ready) or {}
    local authorization = definition.cleanup and
        definition.cleanup.allow_cross_owner_consumption and
        self._runner._resource_index:consumption_authorization(definition) or nil
    local lifetime = definition.cleanup and definition.cleanup.lifetime or
        CleanupLifetime.OWNER
    local plan = self._runner._resource_index:validate_plan(self._owner,
        self._identity.invocation_id, lifetime, entries, self._operation_key,
        authorization)
    local retry_plan
    if definition.execution_retry_policy == RetryPolicy.EXPLICIT_RETRY_SAFE and
            definition.cleanup ~= nil and lifetime ~= CleanupLifetime.COMMAND then
        retry_plan = self._runner._resource_index:validate_plan(self._owner,
            self._identity.invocation_id, CleanupLifetime.COMMAND, entries,
            self._operation_key, authorization)
    end
    return plan, retry_plan
end

---Executes one read-only observation or mutating command attempt.
---@param ready any
---@param context table
---@param plan table
---@return table
function Invocation:execute_attempt(ready, context, plan)
    self._stage = 'execution'
    if self._deadline:remaining_ms() == 0 then
        error('command deadline expired', 2)
    end
    local definition = self._definition
    local outcome
    if Internals.read_only(definition) then
        local observed, result, evidence = Internals.poll(self._runner,
            self._deadline, function() return self:current_stage() end,
            function() return definition.execute(context, self._request, ready) end)
        self._latest_evidence = Internals.latest_gate_evidence(result, evidence,
            self._latest_evidence)
        if not observed then error(Internals.gate_failure(result, evidence), 2) end
        outcome = {kind='executed', public_result=result.value, receipt=result,
            intrinsic_evidence=result.evidence}
    else
        self._identity.attempt_cleanup_checkpoint = type(
            self._runner._cleanup_service.commandCheckpoint) == 'function' and
            self._runner._cleanup_service:commandCheckpoint() or
            self._runner._dependencies.cleanup_checkpoint()
        self._mutation_lease = self._runner._cleanup_service:begin_mutation(
            self._identity.invocation_id)
        context = Internals.context(self._runner, self._identity,
            function() return self:current_stage() end, false, false,
            self._mutation_lease)
        local executed, value = Internals.call(definition.execute, context,
            self._request, ready)
        if not executed then
            error(Internals.quarantine_ambiguous(self._runner, self._identity,
                self._owner, self._stage, value, plan), 2)
        end
        local valid, validated = Internals.call(Outcomes.validate_execution,
            value, definition)
        if not valid then
            error(Internals.quarantine_ambiguous(self._runner, self._identity,
                self._owner, self._stage, validated, plan), 2)
        end
        outcome = validated
        self._latest_evidence = outcome.evidence or self._latest_evidence
    end
    return outcome
end

---Registers an attempt effect before any later lifecycle action.
---@param outcome table
---@param plan table
---@param retry_plan? table
function Invocation:register_effect(outcome, plan, retry_plan)
    if outcome.effect_receipt == nil then return end
    self._stage = 'cleanup_registration'
    local selected_plan = outcome.kind == 'retry' and
        (retry_plan or plan) or plan
    local lifetime = outcome.kind == 'retry' and CleanupLifetime.COMMAND or nil
    local registered, value = Internals.call(Internals.register_cleanup,
        self._runner, self._definition, self._identity, self._owner,
        selected_plan, outcome, self._mutation_lease, lifetime)
    if not registered then error(Internals.error_text(value), 2) end
    self._transaction = value
    self._stage = 'execution'
end

---Completes the attempt return boundary and prepares an explicit retry.
---@param outcome table
---@return boolean
function Invocation:finish_attempt(outcome)
    if not Internals.read_only(self._definition) and
            not self._deadline:check_execution_return() then
        error('command deadline expired during execution', 2)
    end
    if outcome.kind ~= 'retry' then return false end
    self._latest_evidence = Internals.record_retry(self._runner,
        self._retry_attempts, self._attempt_receipts, self._attempt, outcome)
    self._mutation_lease:release()
    self._mutation_lease = nil
    self._stage = 'retry_cleanup'
    Internals.finish_retry_cleanup(self._runner, self._identity.invocation_id,
        self._identity.attempt_cleanup_checkpoint)
    self._transaction = nil
    self._stage = 'retry_wait'
    local waited, failure = Internals.wait(self._runner, self._deadline)
    if not waited then error(failure, 2) end
    self._attempt = self._attempt + 1
    return true
end

---Verifies the terminal attempt using the command's intrinsic policy.
---@param outcome table
function Invocation:verify_intrinsic(outcome)
    if outcome.kind == 'failed' then error(outcome.message, 2) end
    self._stage = 'intrinsic_verification'
    local definition = self._definition
    if definition.intrinsic_verification == IntrinsicKind.CALLBACK then
        local context = Internals.context(self._runner, self._identity,
            function() return self:current_stage() end, true, false, nil)
        local verified, result, latest = Internals.poll(self._runner,
            self._deadline, function() return self:current_stage() end,
            function()
                return definition.verify(context, self._request, outcome.receipt)
            end, true)
        self._latest_intrinsic_evidence = type(result) == 'table' and
            result.evidence or latest
        self._latest_evidence = self._latest_intrinsic_evidence or
            self._latest_evidence
        if not verified then error(Internals.gate_failure(result, latest), 2) end
        if Outcomes.is_effect_absent(result) then
            assert(self._transaction ~= nil,
                'effect_absent requires registered cleanup')
            self._runner._cleanup_service:abandonSelfRolledBack(
                self._transaction:transaction_id(), self._mutation_lease, result)
            error(result.message, 2)
        end
    elseif definition.intrinsic_verification ==
            IntrinsicKind.PRIMARY_OBSERVATION then
        self._latest_intrinsic_evidence = outcome.intrinsic_evidence or
            {kind='primary_observation'}
        self._latest_evidence = self._latest_intrinsic_evidence
    elseif definition.intrinsic_verification ==
            IntrinsicKind.EXECUTION_RECEIPT then
        assert(outcome.receipt ~= nil,
            'execution_receipt verification requires an immutable receipt')
        self._latest_intrinsic_evidence = outcome.receipt
        self._latest_evidence = self._latest_intrinsic_evidence
    else
        error('command has an unsupported intrinsic verification policy', 2)
    end
end

---Runs optional caller verification against the terminal observation.
---@param outcome table
function Invocation:verify_caller(outcome)
    if self._options.verify == nil then return end
    self._stage = 'caller_verification'
    local verified, result, latest = Internals.poll(self._runner, self._deadline,
        function() return self:current_stage() end, function()
            local observation = Internals.diagnostics:sanitize({name=self._name,
                kind=self._definition.kind, public_result=outcome.public_result,
                receipt=outcome.receipt, attempt_count=self._attempt,
                retry_attempts=self._retry_attempts,
                attempt_receipts=self._attempt_receipts,
                stable_target_identity=self._identity.target_identity,
                elapsed_ms=self._runner._dependencies.now_ms() -
                    self._deadline_started_at_ms,
                remaining_ms=self._deadline:remaining_ms(),
                latest_intrinsic_evidence=self._latest_intrinsic_evidence},
                'caller verification observation')
            local accepted = self._options.verify(observation)
            return accepted and Outcomes.ready(true) or
                Outcomes.pending('caller verification is not yet satisfied')
        end, false, true)
    self._latest_evidence = Internals.latest_gate_evidence(result, latest,
        self._latest_evidence)
    if not verified then error(Internals.gate_failure(result, latest), 2) end
end

---Runs attempts followed by intrinsic and caller verification.
---@return any
function Invocation:run()
    self._stage = 'preflight'
    self._identity.cleanup_checkpoint =
        self._runner._dependencies.cleanup_checkpoint()
    local outcome
    repeat
        local ready, context = self:run_preflight()
        local plan, retry_plan = self:plan_claims(ready, context)
        outcome = self:execute_attempt(ready, context, plan)
        self:register_effect(outcome, plan, retry_plan)
    until not self:finish_attempt(outcome)
    self:verify_intrinsic(outcome)
    self:verify_caller(outcome)
    return outcome.public_result
end

---Releases the current mutation lease and merges any release failure.
---@param completed boolean
---@param failure? string
---@param terminal_stage string
---@return boolean, string|nil, string
function Invocation:release_mutation(completed, failure, terminal_stage)
    if not self._mutation_lease then return completed, failure, terminal_stage end
    local released, value = Internals.call(function()
        self._mutation_lease:release()
    end)
    self._mutation_lease = nil
    if not released then
        failure = Internals.append_failure(failure, 'mutation_lease_release',
            value, self._latest_evidence)
        if completed then terminal_stage = 'mutation_lease_release' end
        completed = false
    end
    return completed, failure, terminal_stage
end

---Discovers all command-lifetime cleanup transactions for finalization.
---@return boolean, table, any?
function Invocation:discover_cleanup()
    local pending = {}
    if self._transaction ~= nil then pending[1] = self._transaction end
    if type(self._runner._cleanup_service.pendingCommandTransactions) ~=
            'function' then
        return true, pending, nil
    end
    local discovered, value = Internals.call(function()
        local candidates = self._runner._cleanup_service:
            pendingCommandTransactions(self._identity.invocation_id)
        assert(type(candidates) == 'table',
            'command cleanup discovery must return a table')
        local count, greatest_index = 0, 0
        for index in pairs(candidates) do
            assert(type(index) == 'number' and index >= 1 and index % 1 == 0,
                'command cleanup discovery must return an array')
            count = count + 1
            greatest_index = math.max(greatest_index, index)
        end
        assert(count == greatest_index,
            'command cleanup discovery must return a contiguous array')
        for _, candidate in ipairs(candidates) do
            local duplicate = false
            for _, known in ipairs(pending) do
                if known == candidate then duplicate = true break end
            end
            if not duplicate then pending[#pending + 1] = candidate end
        end
        return pending
    end)
    if not discovered then return false, pending, value end
    return true, value, nil
end

---Runs final cleanup and retained-subject refresh with failure precedence.
---@param completed boolean
---@param failure? string
---@param terminal_stage string
---@return boolean, string|nil, string
function Invocation:finalize_resources(completed, failure, terminal_stage)
    local discovered, pending, discovery_failure = self:discover_cleanup()
    if not discovered then
        failure = Internals.append_failure(failure, 'command_cleanup_discovery',
            discovery_failure, self._latest_evidence)
        if completed then terminal_stage = 'command_cleanup_discovery' end
        completed = false
    end
    for _, transaction in ipairs(pending) do
        local prior = failure
        failure = Internals.finish_command_cleanup(self._definition, transaction,
            failure, self._latest_evidence)
        if prior == nil and failure ~= nil then terminal_stage = 'command_cleanup' end
    end
    completed = failure == nil
    if completed then
        self._stage = 'retained_subject_refresh'
        local refreshed, value = Internals.call(
            self._runner._refresh_retained_subjects, self._identity)
        if not refreshed then
            completed = false
            terminal_stage = self._stage
            failure = Internals.stage_failure(self._stage, value,
                self._latest_evidence)
        end
    end
    return completed, failure, terminal_stage
end

---Publishes the terminal envelope and merges projection failures.
---@param completed boolean
---@param failure? string
---@param terminal_stage string
---@return boolean, string|nil
function Invocation:publish_terminal(completed, failure, terminal_stage)
    local published, value = Internals.call(function()
        Internals.publish(self._runner, 'command.finished', {name=self._name,
            status=completed and 'success' or 'failure',
            stage=completed and 'completed' or terminal_stage,
            operation_key=self._operation_key, attempt_count=self._attempt,
            retry_attempts=self._retry_attempts,
            duration_ms=math.max(0, math.floor(
                self._runner._dependencies.now_ms() - self._started_at_ms))})
    end)
    if not published then
        failure = Internals.append_failure(failure,
            CommandFailureStage.RESULT_PROJECTION, value,
            self._latest_evidence)
        completed = false
    end
    return completed, failure
end

---Finalizes one protected invocation and returns or raises its terminal result.
---@param completed boolean
---@param result any
---@return any
function Invocation:finalize(completed, result)
    local terminal_stage = completed and 'completed' or self._stage
    local failure = not completed and Internals.stage_failure(self._stage,
        result, self._latest_evidence) or nil
    completed, failure, terminal_stage = self:release_mutation(completed,
        failure, terminal_stage)
    completed, failure, terminal_stage = self:finalize_resources(completed,
        failure, terminal_stage)
    completed, failure = self:publish_terminal(completed, failure,
        terminal_stage)
    if not completed then error(failure, 0) end
    return result
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
    local invocation = Invocation.new(self, name, arguments, options)
    invocation:normalize()
    invocation:publish_start()
    local completed, result = xpcall(function()
        return invocation:run()
    end, debug.traceback)
    return invocation:finalize(completed, result)
end

return Runner
