-- Owns run-scoped atomic cleanup registration and lifecycle-event publication.

local CleanupRegistry = require('dwarfspec.driver.cleanup.cleanup_registry')
local CleanupTransaction = require('dwarfspec.driver.cleanup.cleanup_transaction')
local Diagnostics = require('dwarfspec.driver.command.diagnostics')
local CleanupState = require('dwarfspec.protocol.enums.cleanup_states')
local CleanupTrigger = require(
    'dwarfspec.protocol.enums.cleanup_execution_triggers')
local CleanupLifetime = require('dwarfspec.protocol.enums.cleanup_lifetimes')
local OwnerScope = require('dwarfspec.protocol.enums.execution_owner_scopes')
local Outcomes = require('dwarfspec.driver.command.outcomes')
local Revision = require('dwarfspec.protocol.verified_execution_revision')
local events = require('dwarfspec.protocol.events')

local LEASE_STATE = setmetatable({}, {__mode='k'})

---@class dwarfspec.CleanupRegistrationService
---@field private _service_run_id string
---@field private _resource_index dwarfspec.ResourceDependencyIndex
---@field private _now_ms fun(): number
---@field private _registries table<string, dwarfspec.CleanupRegistry>
---@field private _transactions table<string, dwarfspec.CleanupTransaction>
---@field private _transaction_records table<string, table>
---@field private _next_transaction_id integer
---@field private _next_registration_ordinals table<string, integer>
---@field private _journal table[]
---@field private _publish_event? fun(event: dwarfspec.CleanupLifecycleEvent)
---@field private _read_journal? fun(): dwarfspec.CleanupLifecycleEvent[]
---@field private _closed_owners table<string, true>
---@field private _executing_owners table<string, true>
---@field private _owner_results table<string, table>
---@field private _quarantine fun(evidence: table)
---@field private _recover fun(transaction_id: string, proof: table)
---@field private _active_mutation_invocation_id? string
local CleanupRegistrationService = {}
CleanupRegistrationService.__index = CleanupRegistrationService

---@class dwarfspec.CleanupMutationLease
local MutationLease = {}
MutationLease.__index = MutationLease

---@class dwarfspec.driver.cleanup.CleanupRegistrationServiceInternals
local Internals = {}
Internals.diagnostics = Diagnostics.new({max_depth=8, max_entries=64,
    max_string_length=512, max_records=128, pending_sample_limit=4})

---Returns one bounded nonempty identity string.
---@param value any
---@param label string
---@return string
function Internals.identity(value, label)
    assert(type(value) == 'string' and value ~= '' and #value <= 128,
        label .. ' must be a bounded nonempty string')
    return value
end

---Returns the stable key for one cleanup owner.
---@param owner table
---@return string
function Internals.owner_key(owner)
    return table.concat({owner.owner_scope, owner.service_run_id,
        owner.suite_execution_id or '', owner.test_attempt_id or ''}, ':')
end

---Copies trusted bounded diagnostic data without its read-only metatable.
---@param value any
---@return any
function Internals.plain(value)
    if type(value) ~= 'table' then return value end
    local result = {}
    for key, entry in pairs(value) do result[key] = Internals.plain(entry) end
    return result
end

---Checks that an owner belongs to this service run.
---@param service dwarfspec.CleanupRegistrationService
---@param owner table
---@return table
function Internals.owner(service, owner)
    assert(type(owner) == 'table', 'cleanup owner is required')
    assert(owner.service_run_id == service._service_run_id,
        'cleanup owner belongs to another service run')
    assert(owner.owner_scope == OwnerScope.SERVICE_RUN or
        owner.owner_scope == OwnerScope.SUITE_EXECUTION or
        owner.owner_scope == OwnerScope.TEST_ATTEMPT,
        'cleanup owner has an unsupported scope')
    return Internals.diagnostics:sanitize(owner, 'cleanup owner')
end

---Requires exact owner equality between a validated claim plan and transaction.
---@param left table
---@param right table
function Internals.same_owner(left, right)
    assert(left.owner_scope == right.owner_scope and
        left.service_run_id == right.service_run_id and
        left.suite_execution_id == right.suite_execution_id and
        left.test_attempt_id == right.test_attempt_id,
        'cleanup registration owner does not match its claim plan')
end

---Returns one active mutation lease state owned by this service.
---@param service dwarfspec.CleanupRegistrationService
---@param lease any
---@return table
function Internals.mutation_lease_state(service, lease)
    local state = LEASE_STATE[lease]
    assert(state ~= nil and state.service == service and state.active,
        'cleanup registration requires an active mutation lease')
    return state
end

---Validates a current mutation lease for one command invocation.
---@param service dwarfspec.CleanupRegistrationService
---@param lease any
---@param invocation_id string
function Internals.mutation_lease(service, lease, invocation_id)
    local state = Internals.mutation_lease_state(service, lease)
    assert(state.invocation_id == invocation_id,
        'cleanup registration lease belongs to another invocation')
end

---Validates a runner-issued proof covering every claimed stable identity.
---@param outcome any
---@param expected table[]
---@return table
function Internals.absence_proof(outcome, expected)
    assert(Outcomes.is_effect_absent(outcome),
        'cleanup abandonment requires command.effect_absent outcome')
    local evidence = outcome.evidence
    assert(type(evidence) == 'table',
        'effect_absent outcome requires evidence')
    assert(type(evidence.absent_resources) == 'table',
        'effect_absent outcome requires absent_resources')
    local observed, projection = {}, {}
    for ordinal, resource in ipairs(evidence.absent_resources) do
        assert(type(resource) == 'table',
            ('absence proof resource %d must be a table'):format(ordinal))
        local kind = Internals.identity(resource.resource_kind,
            'absence proof resource_kind')
        local identity = Internals.identity(resource.resource_identity,
            'absence proof resource_identity')
        local key = kind .. '\0' .. identity
        assert(not observed[key], 'absence proof cannot duplicate a resource identity')
        observed[key] = true
        projection[#projection + 1] = {resource_kind=kind,
            resource_identity=identity}
    end
    assert(#projection == #expected,
        'absence proof must cover exactly the transaction claim identities')
    for _, resource in ipairs(expected) do
        assert(observed[resource.resource_kind .. '\0' .. resource.resource_identity],
            'absence proof does not match a transaction claim identity')
    end
    return Internals.diagnostics:sanitize({absent_resources=projection,
        message=outcome.message},
        'cleanup absence proof')
end

---Projects the immutable claimed stable identities for abandonment validation.
---@param resource_index dwarfspec.ResourceDependencyIndex
---@param references table[]
---@return table[]
function Internals.claim_identities(resource_index, references)
    local identities = {}
    for _, reference in ipairs(references) do
        local claim = resource_index:lookup(reference)
        identities[#identities + 1] = {resource_kind=claim.resource_kind,
            resource_identity=claim.resource_identity}
    end
    table.sort(identities, function(left, right)
        return left.resource_kind == right.resource_kind and
            left.resource_identity < right.resource_identity or
            left.resource_kind < right.resource_kind
    end)
    return Internals.diagnostics:sanitize(identities,
        'cleanup transaction claim identities')
end

---Copies only safe transaction lifecycle data into one journal event.
---@param service dwarfspec.CleanupRegistrationService
---@param event string
---@param transaction dwarfspec.CleanupTransaction
---@param record table
---@param details? table
function Internals.publish(service, event, transaction, record, details)
    local timestamp_ms = service._now_ms()
    local projection = {schema=Revision.EVENT_SCHEMA,
        protocol_version=Revision.PROTOCOL_VERSION, event_type=event,
        service_run_id=service._service_run_id, timestamp_ms=timestamp_ms,
        transaction_id=transaction:transaction_id(),
        registration_ordinal=transaction:registration_ordinal(), label=record.label,
        lifetime=record.lifetime, owner_scope=record.owner.owner_scope,
        suite_execution_id=record.owner.suite_execution_id,
        test_attempt_id=record.owner.test_attempt_id,
        repeat_index=record.owner.repeat_index,
        spec_file_identity=record.owner.spec_file_identity,
        test_identity=record.owner.test_identity,
        command_invocation_id=record.command_invocation_id,
        state=transaction:state(), registered_at_ms=record.registered_at_ms}
    if event == 'cleanup.transaction_registered' then
        projection.evidence = details
    end
    if event == 'cleanup.transaction_started' then
        projection.trigger = details.trigger
        projection.execution_started_at_ms = timestamp_ms
    elseif event == 'cleanup.transaction_finished' then
        projection.trigger = details.trigger or record.execution_trigger or
            CleanupTrigger.OWNER_TEARDOWN
        projection.execution_started_at_ms = record.execution_started_at_ms or
            timestamp_ms
        projection.completed_at_ms = timestamp_ms
        projection.disposition = details.disposition
        projection.restore_outcome = details.evidence.restore_succeeded and
            'complete' or 'failed'
        projection.verification_outcome = details.evidence.verification_succeeded and
            'complete' or 'failed'
        projection.evidence = details.evidence
    elseif event == 'cleanup.transaction_abandoned' then
        projection.completed_at_ms = timestamp_ms
        projection.disposition = CleanupState.ABANDONED
        projection.evidence = details.proof
    end
    if event == 'cleanup.transaction_started' then
        record.execution_started_at_ms = projection.execution_started_at_ms
        record.execution_trigger = projection.trigger
    end
    local safe_projection = events.copy_json(Internals.plain(projection),
        'cleanup lifecycle event')
    if service._publish_event ~= nil then
        service._publish_event(events.copy_json(safe_projection,
            'cleanup lifecycle event'))
    else
        service._journal[#service._journal + 1] = safe_projection
    end
end

---Releases this invocation's mutation serialization lease.
function MutationLease:release()
    local state = assert(LEASE_STATE[self], 'invalid cleanup mutation lease')
    assert(state.active, 'cleanup mutation lease is already released')
    state.active = false
    state.service._active_mutation_invocation_id = nil
end

---Converts an exceptional adapter failure to bounded inert journal evidence.
---@param value any
---@return string
function Internals.failure_text(value)
    local succeeded, text = pcall(tostring, value)
    if not succeeded then return '<unprintable registration failure>' end
    if #text <= 480 then return text end
    return text:sub(1, 477) .. '...'
end

---Returns whether terminal evidence records an unresolved claim-release failure.
---@param evidence table
---@return boolean
function Internals.release_failure(evidence)
    for _, failure in ipairs(evidence.failures or {}) do
        if type(failure) == 'string' and failure:find('claim release:', 1, true) then
            return true
        end
    end
    return false
end

---Returns a registry for the owner, creating its owner-local mutable state.
---@param service dwarfspec.CleanupRegistrationService
---@param owner table
---@return dwarfspec.CleanupRegistry
function Internals.registry(service, owner)
    local key = Internals.owner_key(owner)
    local registry = service._registries[key]
    if registry == nil then
        registry = CleanupRegistry.new(function(transaction_id)
            return service._resource_index:dependent_transaction_ids(transaction_id)
        end)
        service._registries[key] = registry
    end
    return registry
end

---Creates one run-scoped registration and lifecycle-journal authority.
---@param options table
---@return dwarfspec.CleanupRegistrationService
function CleanupRegistrationService.new(options)
    assert(type(options) == 'table', 'cleanup registration service options are required')
    assert(type(options.resource_index) == 'table',
        'cleanup registration service requires resource index')
    assert(type(options.now_ms) == 'function',
        'cleanup registration service requires monotonic clock')
    assert(options.quarantine == nil or type(options.quarantine) == 'function',
        'cleanup registration quarantine callback must be callable')
    assert(options.publish_event == nil or type(options.publish_event) == 'function',
        'cleanup lifecycle publisher must be callable')
    assert(options.read_journal == nil or type(options.read_journal) == 'function',
        'cleanup lifecycle journal reader must be callable')
    assert(options.recover == nil or type(options.recover) == 'function',
        'cleanup registration recovery callback must be callable')
    return setmetatable({_service_run_id=Internals.identity(options.service_run_id,
        'service run ID'), _resource_index=options.resource_index,
        _now_ms=options.now_ms, _registries={}, _transactions={},
        _transaction_records={}, _next_transaction_id=0,
        _next_registration_ordinals={}, _journal={},
        _closed_owners={}, _executing_owners={}, _owner_results={},
        _publish_event=options.publish_event, _read_journal=options.read_journal,
        _quarantine=options.quarantine or function() end,
        _recover=options.recover or function() end,
        _active_mutation_invocation_id=nil},
        CleanupRegistrationService)
end

---Acquires the run-scoped lease that protects one mutating command attempt.
---@param command_invocation_id string
---@return dwarfspec.CleanupMutationLease
function CleanupRegistrationService:begin_mutation(command_invocation_id)
    command_invocation_id = Internals.identity(command_invocation_id,
        'command invocation ID')
    assert(self._active_mutation_invocation_id == nil,
        'another mutating command attempt is active')
    self._active_mutation_invocation_id = command_invocation_id
    local lease = setmetatable({}, MutationLease)
    LEASE_STATE[lease] = {service=self, invocation_id=command_invocation_id,
        active=true}
    return lease
end

---Retains and quarantines a mutating adapter failure with an unknown effect.
---@param command_invocation_id string
---@param owner table
---@param evidence table
---@return string
function CleanupRegistrationService:quarantineAmbiguousEffect(
        command_invocation_id, owner, evidence)
    command_invocation_id = Internals.identity(command_invocation_id,
        'command invocation ID')
    owner = Internals.owner(self, owner)
    local safe_evidence = Internals.diagnostics:sanitize(evidence,
        'ambiguous command effect evidence')
    local record_id = self._resource_index:record_ambiguous_effect(
        command_invocation_id, owner, safe_evidence)
    self._quarantine(Internals.diagnostics:sanitize({
        reason='ambiguous_command_effect', record_id=record_id,
        command_invocation_id=command_invocation_id, owner=owner,
        evidence=safe_evidence,
    }, 'ambiguous command effect quarantine evidence'))
    return record_id
end

---Returns pending command-lifetime transactions for one invocation.
---@param command_invocation_id string
---@return dwarfspec.CleanupTransaction[]
function CleanupRegistrationService:pendingCommandTransactions(
        command_invocation_id)
    command_invocation_id = Internals.identity(command_invocation_id,
        'command invocation ID')
    local pending = {}
    for transaction_id, transaction in pairs(self._transactions) do
        local record = self._transaction_records[transaction_id]
        if record.command_invocation_id == command_invocation_id and
                record.lifetime == CleanupLifetime.COMMAND and
                transaction:isPending() then
            pending[#pending + 1] = transaction
        end
    end
    table.sort(pending, function(left, right)
        return left:registration_ordinal() > right:registration_ordinal()
    end)
    return pending
end

---Returns the current run-scoped cleanup transaction checkpoint.
---@return integer
function CleanupRegistrationService:commandCheckpoint()
    return self._next_transaction_id
end

---Returns pending command transactions created after one checkpoint.
---@param command_invocation_id string
---@param checkpoint integer
---@return dwarfspec.CleanupTransaction[]
function CleanupRegistrationService:pendingCommandTransactionsSince(
        command_invocation_id, checkpoint)
    command_invocation_id = Internals.identity(command_invocation_id,
        'command invocation ID')
    assert(type(checkpoint) == 'number' and checkpoint >= 0 and
        checkpoint % 1 == 0 and checkpoint <= self._next_transaction_id,
        'command cleanup checkpoint must identify this service history')
    local pending = {}
    for transaction_id, transaction in pairs(self._transactions) do
        local record = self._transaction_records[transaction_id]
        if record.command_invocation_id == command_invocation_id and
                record.transaction_number > checkpoint and
                transaction:isPending() then
            pending[#pending + 1] = transaction
        end
    end
    table.sort(pending, function(left, right)
        return left:registration_ordinal() > right:registration_ordinal()
    end)
    return pending
end

---Executes checkpoint-selected command transactions through their owner planner.
---@param command_invocation_id string
---@param checkpoint integer
---@param reason string
---@return boolean, table[]
function CleanupRegistrationService:executeCommandTransactionsSince(
        command_invocation_id, checkpoint, reason)
    local transactions = self:pendingCommandTransactionsSince(
        command_invocation_id, checkpoint)
    if #transactions == 0 then return true, {} end
    local first_record = self._transaction_records[
        transactions[1]:transaction_id()]
    local registry = Internals.registry(self, first_record.owner)
    for _, transaction in ipairs(transactions) do
        local record = self._transaction_records[transaction:transaction_id()]
        Internals.same_owner(first_record.owner, record.owner)
    end
    return registry:execute_transactions(transactions, reason,
        CleanupTrigger.COMMAND_FINALLY)
end

---Atomically registers one effect-backed cleanup transaction and active claims.
---@param registration table
---@return dwarfspec.CleanupTransaction
function CleanupRegistrationService:register(registration)
    assert(type(registration) == 'table', 'cleanup registration is required')
    local owner = Internals.owner(self, registration.owner)
    assert(not self._closed_owners[Internals.owner_key(owner)],
        'cleanup registration is closed for this owner')
    assert(not self._executing_owners[Internals.owner_key(owner)],
        'cleanup registration is forbidden during cleanup execution')
    local receipt_type = type(registration.receipt)
    assert(receipt_type == 'boolean' or receipt_type == 'number' or
        receipt_type == 'string' or receipt_type == 'table',
        'cleanup registration receipt must be bounded plain data')
    assert(type(registration.restore) == 'function' and type(registration.verify) == 'function',
        'cleanup registration requires restore and verification callbacks')
    local post_effect_registrations = registration.registrations
    if post_effect_registrations == nil then
        assert(type(registration.plan) == 'table' and
            type(registration.bindings) == 'table',
            'cleanup registration requires validated plan and claim bindings')
    else
        assert(type(post_effect_registrations) == 'table',
            'post-effect claim registrations must be a table')
        assert(registration.plan == nil and registration.bindings == nil,
            'post-effect registration must omit pre-execution claim data')
    end
    local command_invocation_id = Internals.identity(registration.command_invocation_id,
        'command invocation ID')
    assert(registration.lifetime == CleanupLifetime.COMMAND or
        registration.lifetime == CleanupLifetime.OWNER,
        'cleanup registration has unsupported lifetime')
    Internals.mutation_lease(self, registration.mutation_lease,
        command_invocation_id)
    if registration.plan ~= nil and type(registration.plan.owner) == 'table' then
        Internals.same_owner(owner, registration.plan.owner)
        assert(registration.plan.lifetime == registration.lifetime,
            'cleanup registration lifetime does not match its claim plan')
    end
    local transaction_number = self._next_transaction_id + 1
    local transaction_id = table.concat({self._service_run_id, 'cleanup',
        tostring(transaction_number)}, ':')
    local owner_key = Internals.owner_key(owner)
    local ordinal = (self._next_registration_ordinals[owner_key] or 0) + 1
    local registry = Internals.registry(self, owner)
    local record = {owner=owner, label=Internals.identity(registration.label,
        'cleanup label'), lifetime=registration.lifetime,
        transaction_number=transaction_number,
        command_invocation_id=command_invocation_id,
        registered_at_ms=self._now_ms()}
    local transaction
    transaction = CleanupTransaction.new({transaction_id=transaction_id,
        registration_ordinal=ordinal, label=record.label, receipt=registration.receipt,
        restore=registration.restore, verify=registration.verify, now_ms=self._now_ms,
        cleanup_timeout_ms=registration.cleanup_timeout_ms,
        remove_pending=function(item) registry:remove_pending(item) end,
        claim_references=function()
            return self._resource_index:references_for_transaction(transaction_id)
        end,
        release_verified=function(_, proof)
            if not record.conflicted and
                    #(record.claim_identities or {}) == 0 then return end
            self._resource_index:release_verified(transaction_id, proof)
        end,
        retain_unresolved=function()
            if not record.conflicted and
                    #(record.claim_identities or {}) == 0 then return end
            self._resource_index:retain_unresolved(transaction_id)
        end,
        blocking_dependents=function() return registry:blocking_dependents(transaction_id) end,
        wait=registration.wait, new_cancellation=registration.new_cancellation,
        invoke_readonly_with_scope=
            type(registration.invoke_readonly) == 'function' and
            function(deadline, cancellation, kind, name, ...)
                return registration.invoke_readonly(transaction_id, owner,
                    deadline, cancellation, kind, name, ...)
            end or nil,
        record_diagnostic=registration.record_diagnostic,
        assert_executable=registration.assert_executable,
        on_started=function(item, trigger)
            self._executing_owners[owner_key] = true
            Internals.publish(self, 'cleanup.transaction_started', item, record,
                {trigger=trigger})
        end,
        on_finished=function(item, disposition, evidence)
            self._executing_owners[owner_key] = nil
            Internals.publish(self, 'cleanup.transaction_finished', item, record,
                {disposition=disposition, evidence=evidence})
            if disposition == CleanupState.FAILED then
                self._quarantine(Internals.diagnostics:sanitize({
                    reason=Internals.release_failure(evidence) and
                        'cleanup_claim_release_failed' or 'cleanup_failed',
                    transaction_id=transaction_id, owner=owner, evidence=evidence,
                }, 'cleanup release quarantine evidence'))
            end
            if record.conflicted and disposition == CleanupState.COMPLETE then
                self._recover(transaction_id, evidence)
            end
        end,
        on_abandoned=function(item, proof)
            Internals.publish(self, 'cleanup.transaction_abandoned', item, record,
                {disposition=CleanupState.ABANDONED, proof=proof})
            if record.conflicted then self._recover(transaction_id, proof) end
        end})
    local activation_succeeded, activated_or_error = xpcall(function()
        if post_effect_registrations ~= nil then
            return self._resource_index:register(owner, transaction_id,
                registration.lifetime, post_effect_registrations)
        end
        return self._resource_index:activate(registration.plan,
            transaction_id, registration.bindings)
    end, debug.traceback)
    self._next_transaction_id = transaction_number
    self._next_registration_ordinals[owner_key] = ordinal
    self._transactions[transaction_id] = transaction
    self._transaction_records[transaction_id] = record
    registry:add(transaction)
    if not activation_succeeded then
        record.conflicted = true
        self._resource_index:record_conflicted_registration(transaction_id, owner,
            {reason='post_effect_registration_failed',
                failure=Internals.failure_text(activated_or_error)})
        self._quarantine(Internals.diagnostics:sanitize({
            reason='post_effect_registration_failed', transaction_id=transaction_id,
            owner=owner, failure=Internals.failure_text(activated_or_error),
        }, 'cleanup registration quarantine evidence'))
        Internals.publish(self, 'cleanup.transaction_registered', transaction, record,
            {conflicted=true})
        error('cleanup registration failed after effect: ' ..
            Internals.failure_text(activated_or_error), 2)
    end
    local activated = activated_or_error
    record.claim_identities = Internals.claim_identities(self._resource_index,
        activated)
    Internals.publish(self, 'cleanup.transaction_registered', transaction, record,
        {claim_references=activated})
    return transaction
end

---Rejects registration after the selected lifecycle owner has closed.
---@param owner dwarfspec.ExecutionOwnerIdentity
---@return boolean
function CleanupRegistrationService:assertRegistrationOpen(owner)
    owner = Internals.owner(self, owner)
    assert(not self._closed_owners[Internals.owner_key(owner)],
        'cleanup registration is closed for this owner')
    assert(not self._executing_owners[Internals.owner_key(owner)],
        'cleanup registration is forbidden during cleanup execution')
    return true
end

---Verifies one public registration's pending ownership, claims, and journal event.
---@param transaction_id string
---@param owner dwarfspec.ExecutionOwnerIdentity
---@return boolean
function CleanupRegistrationService:verifyRegistration(transaction_id, owner)
    transaction_id = Internals.identity(transaction_id,
        'cleanup transaction ID')
    owner = Internals.owner(self, owner)
    local transaction = assert(self._transactions[transaction_id],
        'cleanup registration transaction was not retained')
    local record = assert(self._transaction_records[transaction_id],
        'cleanup registration record was not retained')
    Internals.same_owner(owner, record.owner)
    assert(transaction:isPending(),
        'cleanup registration transaction is not pending')
    local references = self._resource_index:references_for_transaction(
        transaction_id)
    local identities = Internals.claim_identities(self._resource_index,
        references)
    assert(#identities == #(record.claim_identities or {}),
        'cleanup registration claim ownership is incomplete')
    for ordinal, expected in ipairs(record.claim_identities or {}) do
        local actual = identities[ordinal]
        assert(actual.resource_kind == expected.resource_kind and
            actual.resource_identity == expected.resource_identity,
            'cleanup registration claim ownership changed')
    end
    local found = false
    for _, event in ipairs(self:journal()) do
        if event.event_type == 'cleanup.transaction_registered' and
                event.transaction_id == transaction_id then
            found = true
            break
        end
    end
    assert(found, 'cleanup registration event was not journaled')
    return true
end

---Authorizes claim release for one service-owned successfully verified cleanup.
---@param transaction_id string
---@param proof table
---@return string
function CleanupRegistrationService:authorizeRelease(transaction_id, proof)
    transaction_id = Internals.identity(transaction_id,
        'cleanup transaction ID')
    local transaction = assert(self._transactions[transaction_id],
        'claim release transaction is not owned by this cleanup service')
    assert(transaction:state() == CleanupState.RUNNING,
        'claim release requires a running cleanup transaction')
    assert(type(proof) == 'table' and proof.restore_succeeded == true and
        proof.verification_succeeded == true,
        'claim release requires successful cleanup proof')
    return CleanupState.COMPLETE
end

---Closes registration and terminalizes all pending work for one owner.
---@param owner dwarfspec.ExecutionOwnerIdentity
---@param reason string
---@param interrupted boolean|nil
---@return boolean, table
function CleanupRegistrationService:finalize_owner(owner, reason, interrupted)
    owner = Internals.owner(self, owner)
    assert(type(reason) == 'string' and reason ~= '',
        'cleanup finalization reason must be a nonempty string')
    local key = Internals.owner_key(owner)
    if self._owner_results[key] ~= nil then
        return self._owner_results[key].confirmed,
            Internals.diagnostics:sanitize(self._owner_results[key],
                'cleanup owner result')
    end
    self._closed_owners[key] = true
    local registry = Internals.registry(self, owner)
    local confirmed, failures = registry:execute_all(reason,
        CleanupTrigger.OWNER_TEARDOWN)
    if interrupted then
        local unresolved = false
        for _, transaction in ipairs(registry:pending_transactions()) do
            unresolved = true
            CleanupTransaction._mark_unconfirmed(transaction, {
                reason='owner_interrupted', owner=owner,
                finalization_reason=reason,
            })
        end
        if unresolved then
            confirmed = false
            failures[#failures + 1] = 'cleanup owner interrupted'
        end
    end
    local result = Internals.diagnostics:sanitize({owner=owner,
        confirmed=confirmed and #registry:pending_transactions() == 0,
        failures=failures, reason=reason}, 'cleanup owner result')
    self._owner_results[key] = result
    return result.confirmed, Internals.diagnostics:sanitize(result,
        'cleanup owner result')
end

---Returns the terminal result retained for one finalized cleanup owner.
---@param owner dwarfspec.ExecutionOwnerIdentity
---@return table|nil
function CleanupRegistrationService:owner_result(owner)
    local result = self._owner_results[Internals.owner_key(
        Internals.owner(self, owner))]
    if result == nil then return nil end
    return Internals.diagnostics:sanitize(result, 'cleanup owner result')
end

---Abandons a pending current-lease transaction only after absence proof.
---@param transaction_id string
---@param mutation_lease dwarfspec.CleanupMutationLease
---@param proof table
function CleanupRegistrationService:abandonSelfRolledBack(transaction_id,
        mutation_lease, proof)
    transaction_id = Internals.identity(transaction_id, 'cleanup transaction ID')
    local transaction = assert(self._transactions[transaction_id],
        'cleanup transaction is unknown')
    local record = self._transaction_records[transaction_id]
    assert(transaction:isPending(), 'only pending cleanup can be abandoned')
    local lease_state = Internals.mutation_lease_state(self, mutation_lease)
    assert(record.command_invocation_id == lease_state.invocation_id,
        'cleanup transaction is not owned by the active invocation')
    CleanupTransaction._abandon_verified(transaction,
        Internals.absence_proof(proof, record.claim_identities))
end

---Returns the immutable run-scoped cleanup journal.
---@return table[]
function CleanupRegistrationService:journal()
    if self._read_journal ~= nil then
        return events.copy_json(self._read_journal(), 'cleanup journal')
    end
    return events.copy_json(self._journal, 'cleanup journal')
end

---Returns a detached snapshot of one owner's pending transaction identifiers.
---@param owner table
---@return table<string, true>
function CleanupRegistrationService:pending_ids_for(owner)
    return Internals.registry(self, Internals.owner(self, owner)):pending_ids()
end

return CleanupRegistrationService
