-- Owns run-scoped atomic cleanup registration and the authoritative lifecycle journal.

local CleanupRegistry = require('dwarfspec.driver.cleanup.cleanup_registry')
local CleanupTransaction = require('dwarfspec.driver.cleanup.cleanup_transaction')
local Diagnostics = require('dwarfspec.driver.command.diagnostics')
local CleanupState = require('dwarfspec.protocol.enums.cleanup_states')
local CleanupLifetime = require('dwarfspec.protocol.enums.cleanup_lifetimes')
local OwnerScope = require('dwarfspec.protocol.enums.execution_owner_scopes')
local Outcomes = require('dwarfspec.driver.command.outcomes')

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
---@field private _closed_owners table<string, true>
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
    local projection = {event=event, service_run_id=service._service_run_id,
        timestamp_ms=service._now_ms(), transaction_id=transaction:transaction_id(),
        registration_ordinal=transaction:registration_ordinal(), label=record.label,
        lifetime=record.lifetime, owner=record.owner,
        command_invocation_id=record.command_invocation_id, state=transaction:state()}
    if details ~= nil then projection.details = details end
    service._journal[#service._journal + 1] = Internals.diagnostics:sanitize(
        projection, 'cleanup lifecycle event')
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
    assert(options.recover == nil or type(options.recover) == 'function',
        'cleanup registration recovery callback must be callable')
    return setmetatable({_service_run_id=Internals.identity(options.service_run_id,
        'service run ID'), _resource_index=options.resource_index,
        _now_ms=options.now_ms, _registries={}, _transactions={},
        _transaction_records={}, _next_transaction_id=0,
        _next_registration_ordinals={}, _journal={},
        _closed_owners={}, _owner_results={},
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

---Atomically registers one effect-backed cleanup transaction and active claims.
---@param registration table
---@return dwarfspec.CleanupTransaction
function CleanupRegistrationService:register(registration)
    assert(type(registration) == 'table', 'cleanup registration is required')
    local owner = Internals.owner(self, registration.owner)
    assert(not self._closed_owners[Internals.owner_key(owner)],
        'cleanup registration is closed for this owner')
    assert(type(registration.receipt) == 'table', 'cleanup registration receipt is required')
    assert(type(registration.restore) == 'function' and type(registration.verify) == 'function',
        'cleanup registration requires restore and verification callbacks')
    assert(type(registration.plan) == 'table' and type(registration.bindings) == 'table',
        'cleanup registration requires validated plan and claim bindings')
    local command_invocation_id = Internals.identity(registration.command_invocation_id,
        'command invocation ID')
    assert(registration.lifetime == CleanupLifetime.COMMAND or
        registration.lifetime == CleanupLifetime.OWNER,
        'cleanup registration has unsupported lifetime')
    Internals.mutation_lease(self, registration.mutation_lease,
        command_invocation_id)
    if type(registration.plan.owner) == 'table' then
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
        command_invocation_id=command_invocation_id}
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
            self._resource_index:release_verified(transaction_id, proof)
        end,
        retain_unresolved=function() self._resource_index:retain_unresolved(transaction_id) end,
        blocking_dependents=function() return registry:blocking_dependents(transaction_id) end,
        wait=registration.wait, new_cancellation=registration.new_cancellation,
        invoke_readonly=registration.invoke_readonly,
        record_diagnostic=registration.record_diagnostic,
        assert_executable=registration.assert_executable,
        on_started=function(item, trigger)
            Internals.publish(self, 'cleanup.transaction_started', item, record,
                {trigger=trigger})
        end,
        on_finished=function(item, disposition, evidence)
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
        return self._resource_index:activate(registration.plan, transaction_id,
            registration.bindings)
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
    local confirmed, failures = registry:execute_all(reason)
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
    return Internals.diagnostics:sanitize(self._journal, 'cleanup journal')
end

---Returns a detached snapshot of one owner's pending transaction identifiers.
---@param owner table
---@return table<string, true>
function CleanupRegistrationService:pending_ids_for(owner)
    return Internals.registry(self, Internals.owner(self, owner)):pending_ids()
end

return CleanupRegistrationService
