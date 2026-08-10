-- Executes one validated command lifecycle with a single shared deadline.

local CleanupLifetime = require('dwarfspec.protocol.enums.cleanup_lifetimes')
local CleanupTrigger = require(
    'dwarfspec.protocol.enums.cleanup_execution_triggers')
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
local VerifiedSchemas = require(
    'dwarfspec.protocol.verified_execution_schemas')
local Workflow = require('dwarfspec.driver.command.workflow')

---@class dwarfspec.CommandRunner
---@field private _registry dwarfspec.CommandRegistry
---@field private _resource_index dwarfspec.ResourceDependencyIndex
---@field private _cleanup_service dwarfspec.CleanupRegistrationService
---@field private _dependencies table
---@field private _default_timeout_ms integer
---@field private _next_invocation_ordinal integer
---@field private _active_invocations integer
local Runner = {}
Runner.__index = Runner

---@class dwarfspec.driver.command.RunnerInternals
local Internals = {}
Internals.RUNTIME_DEPENDENCIES = {
    wait=true, resolve_mount=true, resolve_target=true, lookup_claim=true,
    capture_render=true, observe_render=true, wait_frames=true,
    wait_ticks=true, wait_event=true, wait_until=true,
}
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
---@param ancestry? table
---@return table
function Internals.identity(runner, owner, ancestry)
    runner._next_invocation_ordinal = runner._next_invocation_ordinal + 1
    local id = owner.service_run_id .. ':command:' ..
        tostring(runner._next_invocation_ordinal)
    ancestry = ancestry or {}
    local identity = {invocation_id=id,
        root_invocation_id=ancestry.root_invocation_id or id,
        owner_scope=owner.owner_scope, service_run_id=owner.service_run_id,
        suite_execution_id=owner.suite_execution_id,
        test_attempt_id=owner.test_attempt_id}
    for _, field in ipairs({'repeat_index', 'spec_file_identity',
            'test_identity'}) do
        if owner[field] ~= nil then identity[field] = owner[field] end
    end
    if ancestry.parent_invocation_id ~= nil then
        identity.parent_invocation_id = ancestry.parent_invocation_id
    elseif ancestry.parent_cleanup_transaction_id ~= nil then
        identity.parent_cleanup_transaction_id =
            ancestry.parent_cleanup_transaction_id
        identity.root_invocation_id = id
    end
    local schemas = VerifiedSchemas.new()
    if ancestry.parent_identity ~= nil then
        schemas:validate_nested_command_identity(identity,
            ancestry.parent_identity)
    elseif ancestry.parent_cleanup_transaction_id ~= nil then
        schemas:validate_cleanup_command_identity(identity,
            ancestry.parent_cleanup_transaction_id, owner)
    else
        schemas:validate_command_identity(identity)
    end
    return identity
end

---Creates a callback context for the runner's current lifecycle stage.
---@param runner dwarfspec.CommandRunner
---@param identity table
---@param stage fun(): string
---@param read_only boolean|nil
---@param privileged boolean
---@param mutation_lease any
---@param dependencies? table
---@return table
function Internals.context(runner, identity, stage, read_only, privileged,
        mutation_lease, dependencies)
    local options = {dependencies=dependencies or runner._dependencies,
        identity=identity,
        stage=stage(), guard=Context.StageGuard.new(stage)}
    if read_only then return Context.new_read(options) end
    if not privileged then return Context.new_execution(options) end
    return Context.new_privileged_execution(options,
        Context.CleanupRegistrationCapability.new(function(registration)
            registration.owner = {owner_scope=identity.owner_scope,
                service_run_id=identity.service_run_id,
                suite_execution_id=identity.suite_execution_id,
                test_attempt_id=identity.test_attempt_id}
            registration.mutation_lease = mutation_lease
            registration.command_invocation_id = identity.invocation_id
            registration.lifetime = CleanupLifetime.OWNER
            registration.cleanup_timeout_ms =
                registration.cleanup_timeout_ms or
                runner._dependencies.cleanup_timeout_ms
            registration.wait = runner._dependencies.wait
            registration.new_cancellation =
                runner._dependencies.new_cancellation
            registration.invoke_readonly = function(transaction_id,
                    cleanup_owner, deadline, cancellation, kind, name, ...)
                return runner:_invoke_cleanup_readonly(transaction_id,
                    cleanup_owner, deadline, cancellation, kind, name, ...)
            end
            registration.record_diagnostic =
                runner._dependencies.record_diagnostic
            registration.assert_executable = function() end
            return runner._cleanup_service:register(registration)
        end, options.guard))
end

---@class dwarfspec.driver.command.WaitFailure
---@field status 'timed_out'|'failed'
---@field message string

---Waits once while preserving the single deadline and cancellation boundary.
---@param runner dwarfspec.CommandRunner
---@param deadline dwarfspec.CommandDeadline
---@param cancellation? fun(): boolean, string|nil
---@return boolean, dwarfspec.driver.command.WaitFailure|nil
function Internals.wait(runner, deadline, cancellation)
    cancellation = cancellation or runner._dependencies.cancellation
    local cancelled, reason = cancellation()
    if cancelled then
        return false, {status='failed',
            message='cancelled: ' .. tostring(reason)}
    end
    local remaining = deadline:remaining_ms()
    if remaining == 0 then
        return false, {status='timed_out',
            message='command deadline expired'}
    end
    runner._dependencies.wait(remaining)
    if deadline:remaining_ms() >= remaining then
        return false, {status='failed',
            message='command scheduler did not advance time'}
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
---@param cancellation? fun(): boolean, string|nil
---@return boolean, table|string, table|nil, string
function Internals.poll(runner, deadline, stage, invoke, allow_effect_absent,
        retry_errors, cancellation)
    cancellation = cancellation or runner._dependencies.cancellation
    local latest
    while deadline:remaining_ms() > 0 do
        local cancelled, reason = cancellation()
        if cancelled then
            return false, 'cancelled: ' .. tostring(reason), latest, 'failed'
        end
        local ok, result = Internals.call(invoke)
        if not ok then
            local message = Internals.error_text(result)
            if not retry_errors then return false, message, latest, 'failed' end
            latest = {message=message}
            local waited, failure = Internals.wait(runner, deadline, cancellation)
            if not waited then
                return false, failure.message, latest, failure.status
            end
        else
        local valid_gate, gate = Internals.call(Internals.gate, result,
            stage() .. ' callback', allow_effect_absent)
        if not valid_gate then
            return false, Internals.error_text(gate), latest, 'failed'
        end
        if gate.kind == 'ready' then return true, gate, latest, 'passed' end
        if gate.kind == 'fatal' then
            return false, gate.message, gate.evidence, 'fatal'
        end
        if Outcomes.is_effect_absent(gate) then
            return true, gate, latest, 'passed'
        end
        latest = {message=gate.message, evidence=gate.evidence}
        local waited, failure = Internals.wait(runner, deadline, cancellation)
        if not waited then
            return false, failure.message, latest, failure.status
        end
        end
    end
    return false, 'command deadline expired', latest, 'timed_out'
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
        invoke_readonly=function(transaction_id, cleanup_owner, deadline,
                cancellation, kind, name, ...)
            return runner:_invoke_cleanup_readonly(transaction_id,
                cleanup_owner, deadline, cancellation, kind, name, ...)
        end,
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
        transaction:execute('execution retry', CleanupTrigger.COMMAND_FINALLY)
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
---@return string|nil, boolean
function Internals.finish_command_cleanup(definition, transaction, failure,
        evidence)
    local attempted = false
    local succeeded, cleanup_failure = Internals.call(function()
        if transaction == nil or definition.cleanup == nil or
                definition.cleanup.lifetime ~= CleanupLifetime.COMMAND or
                not transaction:isPending() then
            return
        end
        attempted = true
        transaction:execute('command lifecycle finalization',
            CleanupTrigger.COMMAND_FINALLY)
    end)
    if succeeded then return failure, attempted end
    return Internals.append_failure(failure, 'command_cleanup', cleanup_failure,
        evidence), attempted
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

---Publishes optional stage evidence through the lifecycle event seam.
---@param runner dwarfspec.CommandRunner
---@param payload table
function Internals.publish_stage(runner, payload)
    Internals.publish(runner, 'command.stage', payload)
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
        _active_invocations=0,
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

---Installs live command-context callbacks after run namespace composition.
---@param dependencies table<string, function>
function Runner:setRuntimeDependencies(dependencies)
    assert(self._active_invocations == 0,
        'command runtime dependencies cannot change during execution')
    assert(type(dependencies) == 'table',
        'command runtime dependencies must be a table')
    for name, callback in pairs(dependencies) do
        assert(type(name) == 'string' and name ~= '',
            'command runtime dependency names must be nonempty strings')
        assert(Internals.RUNTIME_DEPENDENCIES[name] == true,
            'unsupported command runtime dependency: ' .. name)
        assert(type(callback) == 'function',
            'command runtime dependency ' .. name .. ' must be callable')
        self._dependencies[name] = callback
    end
end

---Registers one immutable built-in definition in this run.
---@param definition table
---@return dwarfspec.CommandDefinition
function Runner:registerBuiltin(definition)
    return self._registry:register_builtin(definition)
end

---Registers one source-attributed immutable project definition in this run.
---@param definition table
---@param source_path string
---@return dwarfspec.CommandDefinition
function Runner:registerProject(definition, source_path)
    return self._registry:register_project(definition, source_path)
end

---Guards manual cleanup-handle mutation against command and cleanup stages.
---@param owner dwarfspec.ExecutionOwnerIdentity
function Runner:assertHandleExecution(owner)
    assert(self._active_invocations == 0,
        'cleanup handle execution is forbidden during command execution')
    self._cleanup_service:assertRegistrationOpen(owner)
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
---@param inheritance? table
---@return table
function Invocation.new(runner, name, arguments, options, inheritance)
    inheritance = inheritance or {}
    return setmetatable({_runner=runner, _name=name, _arguments=arguments,
        _options=options, _definition=inheritance.definition or
            assert(runner._registry:get(name), 'unknown command ' .. name),
        _inheritance=inheritance, _stage='normalization',
        _latest_evidence=nil, _transaction=nil, _mutation_lease=nil,
        _attempt=1, _retry_attempts={}, _attempt_receipts={},
        _pending_observations={}, _cleanup_evidence={}}, Invocation)
end

---Returns the current lifecycle stage for command contexts and diagnostics.
---@return string
function Invocation:current_stage()
    return self._stage
end

---Normalizes input and establishes immutable invocation-wide dependencies.
function Invocation:normalize()
    local normalized, value = Internals.call(function()
        local request = self._inheritance.normalized_request or
            self._definition.normalize(self._arguments)
        if self._definition.privileged_cleanup_registration then
            assert(type(request) == 'table',
                'privileged cleanup request must be a validated table')
        else
            request = Internals.diagnostics:sanitize(request,
                'normalized command request')
        end
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
    if self._inheritance.deadline ~= nil then
        assert(self._options.timeout_ms == nil,
            'nested commands inherit their parent deadline')
        self._deadline = self._inheritance.deadline
        self._timeout_ms = self._inheritance.timeout_ms
        self._deadline_started_at_ms = self._inheritance.deadline_started_at_ms
        self._owner = self._inheritance.owner
        self._cancellation = self._inheritance.cancellation
        self._identity = Internals.identity(self._runner, self._owner,
            self._inheritance.ancestry)
    else
        self._timeout_ms = self._options.timeout_ms or
            self._definition.default_timeout_ms or self._runner._default_timeout_ms
        self._deadline = Deadline.new(self._runner._dependencies.now_ms,
            self._timeout_ms)
        self._deadline_started_at_ms = self._deadline:expires_at_ms() -
            self._timeout_ms
        self._owner = self._runner._dependencies.owner()
        self._cancellation = self._runner._dependencies.cancellation
        self._identity = Internals.identity(self._runner, self._owner)
    end
    self._started_at_ms = self._runner._dependencies.now_ms()
    self._context_dependencies = {}
    for key, entry in pairs(self._runner._dependencies) do
        self._context_dependencies[key] = entry
    end
    self._context_dependencies.remaining_ms = function()
        return self._deadline:remaining_ms()
    end
    self._context_dependencies.cancellation = self._cancellation
    self._context_dependencies.invoke_readonly = function(kind, name, ...)
        return self:invoke_readonly(kind, name, ...)
    end
    self._context_dependencies.execute_step = function(step, state)
        return self:execute_workflow_step(step, state)
    end
end

---Invokes one nested public read-only command under inherited boundaries.
---@param kind string
---@param name string
---@param arguments? table
---@param options? table
---@return any
function Invocation:invoke_readonly(kind, name, arguments, options)
    assert(kind == CommandKind.QUERY or kind == CommandKind.ASSERTION,
        'nested invocation requires a read-only command kind')
    arguments = arguments or {}
    options = Internals.options(options)
    assert(options.timeout_ms == nil,
        'nested commands inherit their parent deadline')
    local definition = assert(self._runner._registry:get(name),
        'unknown command ' .. tostring(name))
    assert(definition.kind == kind,
        'nested command kind does not match its registered definition')
    local child = Invocation.new(self._runner, name, arguments, options, {
        deadline=self._deadline, timeout_ms=self._timeout_ms,
        deadline_started_at_ms=self._deadline_started_at_ms,
        cancellation=self._cancellation, owner=self._owner,
        ancestry={root_invocation_id=self._identity.root_invocation_id,
            parent_invocation_id=self._identity.invocation_id,
            parent_identity=self._identity}})
    child:normalize()
    child:publish_start()
    local completed, result = xpcall(function() return child:run() end,
        debug.traceback)
    return child:finalize(completed, result)
end

---Executes one workflow step as an inherited internal invocation.
---@param step dwarfspec.WorkflowStepDefinition
---@param state dwarfspec.WorkflowState
---@return any
function Invocation:execute_workflow_step(step, state)
    local child = Invocation.new(self._runner,
        self._name .. '.' .. step.name, {}, {}, {definition=step,
            normalized_request=state, deadline=self._deadline,
            timeout_ms=self._timeout_ms,
            deadline_started_at_ms=self._deadline_started_at_ms,
            cancellation=self._cancellation, owner=self._owner,
            ancestry={root_invocation_id=self._identity.root_invocation_id,
                parent_invocation_id=self._identity.invocation_id,
                parent_identity=self._identity}})
    child:normalize()
    child:publish_start()
    local completed, result = xpcall(function() return child:run() end,
        debug.traceback)
    return child:finalize(completed, result)
end

---Publishes the invocation start envelope before command execution begins.
function Invocation:publish_start()
    local published, failure = Internals.call(function()
        local safe_arguments = self._request
        if self._definition.privileged_cleanup_registration then
            safe_arguments = {label=self._request.label,
                receipt=self._request.receipt,
                resource_claims=self._request.resource_claims,
                cleanup_timeout_ms=self._request.cleanup_timeout_ms}
        end
        Internals.publish(self._runner, 'command.started', {name=self._name,
            subject_identity=self._identity.target_identity or '<none>',
            safe_arguments=safe_arguments, operation_key=self._operation_key,
            command=self._identity})
    end)
    if not published then
        error(Internals.stage_failure(CommandFailureStage.RESULT_PROJECTION,
            failure, nil), 0)
    end
end

---Returns elapsed invocation time as a nonnegative integer.
---@return integer
function Invocation:elapsed_ms()
    return math.max(0, math.floor(
        self._runner._dependencies.now_ms() - self._started_at_ms))
end

---Publishes one bounded stage observation with complete invocation ancestry.
---@param stage string
---@param status string
---@param details? table
function Invocation:publish_stage(stage, status, details)
    details = details or {}
    local payload = {name=self._name, stage=stage, status=status,
        duration_ms=self:elapsed_ms(), configured_timeout_ms=self._timeout_ms,
        attempt=self._attempt, command=self._identity,
        operation_key=self._operation_key,
        subject_identity=self._identity.target_identity}
    for key, value in pairs(details) do payload[key] = value end
    Internals.publish_stage(self._runner, payload)
end

---Publishes at most one summarized pending observation for one stage.
---@param stage string
---@param evidence any
function Invocation:publish_pending(stage, evidence)
    if evidence == nil or self._pending_observations[stage] then return end
    self._pending_observations[stage] = true
    self:publish_stage(stage, 'pending', {last_observation=evidence})
end

---Classifies and publishes a terminal gate observation.
---@param stage string
---@param accepted boolean
---@param result any
---@param evidence any
---@param outcome_status? string
function Invocation:publish_gate(stage, accepted, result, evidence,
        outcome_status)
    self:publish_pending(stage, evidence)
    if accepted then
        self:publish_stage(stage, 'passed', {
            last_observation=type(result) == 'table' and result.evidence or
                evidence})
        return
    end
    local status = outcome_status or 'failed'
    self:publish_stage(stage, status, {last_observation=evidence,
        failure=Internals.error_text(result)})
end

---Runs initial and volatile preflight validation for the current attempt.
---@return any, table
function Invocation:run_preflight()
    self._stage = 'preflight'
    self._identity.attempt = self._attempt
    local context = Internals.context(self._runner, self._identity,
        function() return self:current_stage() end, true, false, nil,
        self._context_dependencies)
    local ready
    for _ = 1, 2 do
        local accepted, result, evidence, observation_status = Internals.poll(
            self._runner,
            self._deadline, function() return self:current_stage() end,
            function()
                return self._definition.preflight(context, self._request)
            end, nil, nil, self._cancellation)
        self._latest_evidence = Internals.latest_gate_evidence(result, evidence,
            self._latest_evidence)
        self:publish_gate('preflight', accepted, result, evidence,
            observation_status)
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
    self._attempt_terminal_published = false
    self:publish_stage('attempt', 'started')
    if self._deadline:remaining_ms() == 0 then
        error('command deadline expired', 2)
    end
    local definition = self._definition
    local outcome
    if Internals.read_only(definition) then
        local observed, result, evidence = Internals.poll(self._runner,
            self._deadline, function() return self:current_stage() end,
            function() return definition.execute(context, self._request, ready) end,
            nil, nil, self._cancellation)
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
            function() return self:current_stage() end, false,
            definition.privileged_cleanup_registration == true,
            self._mutation_lease, self._context_dependencies)
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
    self._outcome = outcome
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
    if not self._deadline:check_execution_return() then
        self:publish_stage('attempt', 'timed_out', {
            last_observation=outcome.evidence,
            receipt_summary=outcome.receipt,
            effect_reported=outcome.effect_receipt ~= nil})
        self._attempt_terminal_published = true
        error('command deadline expired during execution', 2)
    end
    self:publish_stage('attempt', outcome.kind == 'failed' and 'failed' or
        outcome.kind == 'retry' and 'retry' or 'completed', {
            last_observation=outcome.evidence,
            receipt_summary=outcome.receipt,
            effect_reported=outcome.effect_receipt ~= nil})
    self._attempt_terminal_published = true
    if outcome.kind ~= 'retry' then return false end
    self._latest_evidence = Internals.record_retry(self._runner,
        self._retry_attempts, self._attempt_receipts, self._attempt, outcome)
    self._mutation_lease:release()
    self._mutation_lease = nil
    self._stage = 'retry_cleanup'
    local retry_cleanup = Internals.pending_command_transactions(self._runner,
        self._identity.invocation_id,
        self._identity.attempt_cleanup_checkpoint)
    local cleanup_attempted = #retry_cleanup > 0
    if cleanup_attempted then
        self:publish_stage('command_cleanup', 'attempted', {
            cleanup_evidence={reason='execution retry'}})
    end
    local cleaned, cleanup_failure = Internals.call(
        Internals.finish_retry_cleanup, self._runner,
        self._identity.invocation_id,
        self._identity.attempt_cleanup_checkpoint)
    if not cleaned then
        if cleanup_attempted then
            self:publish_stage('command_cleanup', 'failed', {cleanup_evidence={
                reason='execution retry', failure=Internals.error_text(
                    cleanup_failure)}})
        end
        error(cleanup_failure, 2)
    end
    if cleanup_attempted then
        self._cleanup_evidence[#self._cleanup_evidence + 1] = {
            attempt=self._attempt, reason='execution retry', verified=true}
        self:publish_stage('command_cleanup', 'verified', {
            cleanup_evidence=self._cleanup_evidence[#self._cleanup_evidence]})
    end
    self._transaction = nil
    self._stage = 'retry_wait'
    local waited, failure = Internals.wait(self._runner, self._deadline,
        self._cancellation)
    if not waited then error(failure.message, 2) end
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
            function() return self:current_stage() end, true, false, nil,
            self._context_dependencies)
        local verified, result, latest, observation_status = Internals.poll(
            self._runner,
            self._deadline, function() return self:current_stage() end,
            function()
                return definition.verify(context, self._request, outcome.receipt)
            end, true, nil, self._cancellation)
        self._latest_intrinsic_evidence = type(result) == 'table' and
            result.evidence or latest
        self._latest_evidence = self._latest_intrinsic_evidence or
            self._latest_evidence
        self:publish_gate('intrinsic_verification', verified, result, latest,
            observation_status)
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
        self:publish_stage('intrinsic_verification', 'passed', {
            last_observation=self._latest_intrinsic_evidence})
    elseif definition.intrinsic_verification ==
            IntrinsicKind.EXECUTION_RECEIPT then
        assert(outcome.receipt ~= nil,
            'execution_receipt verification requires an immutable receipt')
        self._latest_intrinsic_evidence = outcome.receipt
        self._latest_evidence = self._latest_intrinsic_evidence
        self:publish_stage('intrinsic_verification', 'passed', {
            last_observation=self._latest_intrinsic_evidence,
            receipt_summary=outcome.receipt})
    else
        error('command has an unsupported intrinsic verification policy', 2)
    end
end

---Runs optional caller verification against the terminal observation.
---@param outcome table
function Invocation:verify_caller(outcome)
    if self._options.verify == nil then return end
    self._stage = 'caller_verification'
    local verified, result, latest, observation_status = Internals.poll(
        self._runner, self._deadline,
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
            assert(type(accepted) == 'boolean',
                'caller verification must return a boolean')
            return accepted and Outcomes.ready(true) or
                Outcomes.pending('caller verification is not yet satisfied')
        end, false, true, self._cancellation)
    self._latest_evidence = Internals.latest_gate_evidence(result, latest,
        self._latest_evidence)
    self:publish_gate('caller_verification', verified, result, latest,
        observation_status)
    if not verified then error(Internals.gate_failure(result, latest), 2) end
end

---Runs the ordered internal steps and projects one stable public result.
---@return table
function Invocation:run_workflow()
    self:run_preflight()
    self._stage = 'execution'
    self._attempt_terminal_published = false
    self:publish_stage('attempt', 'started')
    self._stage = 'workflow'
    local workflow = Workflow.new(self._definition.workflow, self._request)
    local state = workflow:execute_steps(function(step, current_state)
        return self:execute_workflow_step(step, current_state)
    end)
    self._stage = 'execution'
    local projected = workflow:project(state)
    local outcome = Outcomes.executed(projected, {outputs=state.outputs})
    self._outcome = outcome
    self:publish_stage('attempt', 'completed', {
        receipt_summary=outcome.receipt})
    self._attempt_terminal_published = true
    return outcome
end

---Runs attempts followed by intrinsic and caller verification.
---@return any
function Invocation:run()
    self._stage = 'preflight'
    self._identity.cleanup_checkpoint =
        self._runner._dependencies.cleanup_checkpoint()
    local outcome
    if self._definition.kind == CommandKind.WORKFLOW then
        outcome = self:run_workflow()
    else
        repeat
            local ready, context = self:run_preflight()
            local plan, retry_plan = self:plan_claims(ready, context)
            outcome = self:execute_attempt(ready, context, plan)
            self:register_effect(outcome, plan, retry_plan)
        until not self:finish_attempt(outcome)
    end
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
        local attempted
        failure, attempted = Internals.finish_command_cleanup(self._definition,
            transaction, failure, self._latest_evidence)
        if attempted then
            self:publish_stage('command_cleanup', 'attempted', {
                cleanup_evidence={reason='command lifecycle finalization'}})
            local verified = prior == failure
            local evidence = {reason='command lifecycle finalization',
                verified=verified}
            self._cleanup_evidence[#self._cleanup_evidence + 1] = evidence
            self:publish_stage('command_cleanup',
                verified and 'verified' or 'failed', {
                    cleanup_evidence=evidence})
        end
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

---Projects bounded command-specific failure evidence without masking failure.
---@param failure string
---@return table|nil, table|nil
function Invocation:project_failure_diagnostics(failure)
    if type(self._definition.diagnostics) ~= 'function' then return nil, nil end
    local projected, projection_failure = Internals.diagnostics:project(
        self._definition.diagnostics, self._request,
        self._outcome and self._outcome.receipt or nil)
    local kind = projected and 'command.failure' or
        'command.diagnostic_projection_failed'
    Internals.call(self._runner._dependencies.record_diagnostic, kind,
        projected or projection_failure or {message=Internals.error_text(failure)})
    return projected, projection_failure
end

---Publishes the terminal envelope and merges projection failures.
---@param completed boolean
---@param failure? string
---@param terminal_stage string
---@return boolean, string|nil
function Invocation:publish_terminal(completed, failure, terminal_stage)
    local published, value = Internals.call(function()
        local diagnostic_evidence, diagnostic_failure
        if not completed then
            diagnostic_evidence, diagnostic_failure =
                self:project_failure_diagnostics(failure)
        end
        local evidence_kind
        if self._options.verify ~= nil then
            evidence_kind = 'intrinsic_and_caller'
        elseif self._definition.intrinsic_verification ==
                IntrinsicKind.EXECUTION_RECEIPT then
            evidence_kind = 'execution_receipt_only'
        else
            evidence_kind = 'intrinsic_only'
        end
        if not completed and not self._attempt_terminal_published and
                (terminal_stage == 'execution' or
                    terminal_stage == 'cleanup_registration') then
            self:publish_stage('attempt', tostring(failure):find(
                'deadline expired', 1, true) and 'timed_out' or 'failed', {
                last_observation=self._latest_evidence,
                failure=failure})
            self._attempt_terminal_published = true
        end
        self:publish_stage('completion', completed and 'completed' or 'failed', {
            last_observation=self._latest_evidence,
            receipt_summary=self._outcome and self._outcome.receipt or nil,
            cleanup_evidence=#self._cleanup_evidence > 0 and
                self._cleanup_evidence or nil,
            diagnostic_evidence=diagnostic_evidence,
            diagnostic_failure=diagnostic_failure,
            focus=diagnostic_evidence and diagnostic_evidence.focus or nil,
            viewscreen=diagnostic_evidence and
                diagnostic_evidence.viewscreen or nil,
            evidence_kind=evidence_kind,
            failure=not completed and failure or nil})
        Internals.publish(self._runner, 'command.finished', {name=self._name,
            status=completed and 'success' or 'failure',
            stage=completed and 'completed' or terminal_stage,
            operation_key=self._operation_key, attempt_count=self._attempt,
            retry_attempts=self._retry_attempts,
            command=self._identity,
            configured_timeout_ms=self._timeout_ms,
            last_observation=self._latest_evidence,
            receipt_summary=self._outcome and self._outcome.receipt or nil,
            cleanup_evidence=#self._cleanup_evidence > 0 and
                self._cleanup_evidence or nil,
            diagnostic_evidence=diagnostic_evidence,
            diagnostic_failure=diagnostic_failure,
            focus=diagnostic_evidence and diagnostic_evidence.focus or nil,
            viewscreen=diagnostic_evidence and
                diagnostic_evidence.viewscreen or nil,
            evidence_kind=evidence_kind,
            duration_ms=self:elapsed_ms()})
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

---Invokes a cleanup-rooted read-only child under cleanup-owned boundaries.
---@param transaction_id string
---@param owner table
---@param deadline dwarfspec.CommandDeadline
---@param cancellation fun(): boolean, string|nil
---@param kind string
---@param name string
---@param arguments? table
---@param options? table
---@return any
function Runner:_invoke_cleanup_readonly(transaction_id, owner, deadline,
        cancellation, kind, name, arguments, options)
    assert(type(transaction_id) == 'string' and transaction_id ~= '',
        'cleanup-rooted command requires a cleanup transaction ID')
    assert(type(owner) == 'table',
        'cleanup-rooted command requires its cleanup owner')
    assert(type(deadline) == 'table' and
        type(deadline.remaining_ms) == 'function',
        'cleanup-rooted command requires its cleanup deadline')
    assert(type(cancellation) == 'function',
        'cleanup-rooted command requires its cleanup cancellation scope')
    assert(kind == CommandKind.QUERY or kind == CommandKind.ASSERTION,
        'cleanup verification can invoke only read-only commands')
    arguments = arguments or {}
    options = Internals.options(options)
    assert(options.timeout_ms == nil,
        'cleanup-rooted commands inherit their cleanup deadline')
    local definition = assert(self._registry:get(name),
        'unknown command ' .. tostring(name))
    assert(definition.kind == kind,
        'cleanup-rooted command kind does not match its definition')
    local child = Invocation.new(self, name, arguments, options, {
        deadline=deadline, timeout_ms=deadline:remaining_ms(),
        deadline_started_at_ms=self._dependencies.now_ms(),
        cancellation=cancellation, owner=owner,
        ancestry={parent_cleanup_transaction_id=transaction_id}})
    child:normalize()
    child:publish_start()
    local completed, result = xpcall(function() return child:run() end,
        debug.traceback)
    return child:finalize(completed, result)
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
    self._active_invocations = self._active_invocations + 1
    local invoked, packed = xpcall(function()
        local invocation = Invocation.new(self, name, arguments, options)
        invocation:normalize()
        invocation:publish_start()
        local completed, result = xpcall(function()
            return invocation:run()
        end, debug.traceback)
        return table.pack(invocation:finalize(completed, result))
    end, function(failure) return failure end)
    self._active_invocations = self._active_invocations - 1
    if not invoked then error(packed, 0) end
    return table.unpack(packed, 1, packed.n)
end

return Runner
