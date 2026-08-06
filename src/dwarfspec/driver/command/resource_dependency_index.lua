-- Run-scoped policy and dependency tracking for effect-backed resource claims.

local DirectedAcyclicGraph = require(
    'dwarfspec.graphs.directed_acyclic_graph')
local CleanupLifetime = require('dwarfspec.protocol.enums.cleanup_lifetimes')
local OwnerScope = require('dwarfspec.protocol.enums.execution_owner_scopes')
local Diagnostics = require('dwarfspec.driver.command.diagnostics')
local Definition = require('dwarfspec.driver.command.definition')

---@class dwarfspec.ResourceDependencyIndex
---@field private _service_run_id string
---@field private _graph dwarfspec.DirectedAcyclicGraph
---@field private _claims table<string, table>
---@field private _transaction_claim_ids table<string, table<string, true>>
---@field private _plans table<table, true>
---@field private _references table<table, string>
---@field private _conflicted_records table<string, table>
---@field private _consumption_authorizations table<table, true>
---@field private _release_authorizer? fun(transaction_id: string, proof: any): string
---@field private _next_claim_ordinal integer
local ResourceDependencyIndex = {}
ResourceDependencyIndex.__index = ResourceDependencyIndex

---@class dwarfspec.driver.command.ResourceDependencyIndexInternals
local Internals = {}
Internals.reference_tokens = setmetatable({}, {__mode='k'})
Internals.max_string_length = 128
Internals.evidence_diagnostics = Diagnostics.new({max_depth=8, max_entries=32,
    max_string_length=512, max_records=256, pending_sample_limit=1})

---Creates a recursively immutable snapshot without retaining caller tables.
---@param value any
---@param copies? table
---@return any
function Internals.freeze(value, copies)
    if type(value) ~= 'table' then return value end
    if Internals.reference_tokens[value] then return value end
    copies = copies or {}
    assert(copies[value] == nil, 'resource claim values must be acyclic')
    copies[value] = true
    local data = {}
    for key, entry in pairs(value) do
        data[Internals.freeze(key, copies)] = Internals.freeze(entry, copies)
    end
    copies[value] = nil
    return setmetatable({}, {
        __index=data,
        __newindex=function() error('resource claim values are immutable', 2) end,
        __pairs=function() return pairs(data) end,
        __len=function() return #data end,
        __metatable=false,
    })
end

---Requires a nonempty string.
---@param value any
---@param label string
---@return string
function Internals.string(value, label)
    assert(type(value) == 'string' and value ~= '',
        label .. ' must be a nonempty string')
    assert(#value <= Internals.max_string_length,
        label .. ' must be bounded')
    return value
end

---Requires a bounded generated claim identifier.
---@param value any
---@param label string
---@return string
function Internals.claim_id(value, label)
    assert(type(value) == 'string' and value ~= '' and #value <= 512,
        label .. ' must be a bounded nonempty string')
    return value
end

---Validates a contiguous array of values.
---@param value any
---@param label string
---@return table
function Internals.array(value, label)
    if value == nil then return {} end
    assert(type(value) == 'table', label .. ' must be an array')
    local count, greatest_index = 0, 0
    for key in pairs(value) do
        assert(type(key) == 'number' and key >= 1 and key % 1 == 0,
            label .. ' must contain positive integer indexes')
        count, greatest_index = count + 1, math.max(greatest_index, key)
    end
    assert(count == greatest_index, label .. ' must be contiguous')
    return value
end

---Returns whether one owner scope is supported.
---@param scope any
---@return boolean
function Internals.owner_scope(scope)
    return scope == OwnerScope.SERVICE_RUN or
        scope == OwnerScope.SUITE_EXECUTION or
        scope == OwnerScope.TEST_ATTEMPT
end

---Validates an execution owner and its complete parent chain.
---@param owner any
---@param service_run_id string
---@return table
function Internals.owner(owner, service_run_id)
    assert(type(owner) == 'table', 'owner must be a table')
    assert(Internals.owner_scope(owner.owner_scope),
        'owner has unsupported owner_scope')
    assert(owner.service_run_id == service_run_id,
        'owner belongs to a different service run')
    local normalized = {owner_scope=owner.owner_scope,
        service_run_id=Internals.string(owner.service_run_id,
            'owner.service_run_id')}
    if owner.owner_scope == OwnerScope.SERVICE_RUN then
        assert(owner.suite_execution_id == nil and owner.test_attempt_id == nil,
            'service-run owner cannot name suite or test')
    elseif owner.owner_scope == OwnerScope.SUITE_EXECUTION then
        normalized.suite_execution_id = Internals.string(owner.suite_execution_id,
            'owner.suite_execution_id')
        assert(owner.test_attempt_id == nil,
            'suite owner cannot name a test')
    else
        normalized.suite_execution_id = Internals.string(owner.suite_execution_id,
            'owner.suite_execution_id')
        normalized.test_attempt_id = Internals.string(owner.test_attempt_id,
            'owner.test_attempt_id')
    end
    return Internals.freeze(normalized)
end

---Returns a stable owner-chain key.
---@param owner table
---@return string
function Internals.owner_key(owner)
    return table.concat({owner.owner_scope, owner.service_run_id,
        owner.suite_execution_id or '', owner.test_attempt_id or ''}, ':')
end

---Returns whether dependent owner is nested inside or equal to prerequisite.
---@param prerequisite table
---@param dependent table
---@return boolean
function Internals.owner_contains(prerequisite, dependent)
    if prerequisite.service_run_id ~= dependent.service_run_id then return false end
    if prerequisite.owner_scope == OwnerScope.SERVICE_RUN then return true end
    if prerequisite.suite_execution_id ~= dependent.suite_execution_id then
        return false
    end
    if prerequisite.owner_scope == OwnerScope.SUITE_EXECUTION then return true end
    return prerequisite.test_attempt_id == dependent.test_attempt_id
end

---Returns a numeric lifetime depth used for dependency direction checks.
---@param owner table
---@param lifetime string
---@return integer
function Internals.lifetime_depth(owner, lifetime)
    local depth = owner.owner_scope == OwnerScope.SERVICE_RUN and 1 or
        owner.owner_scope == OwnerScope.SUITE_EXECUTION and 2 or 3
    return lifetime == CleanupLifetime.COMMAND and depth + 1 or depth
end

---Validates a claim reference against current active state.
---@param index dwarfspec.ResourceDependencyIndex
---@param reference any
---@return table
function Internals.reference(index, reference)
    assert(type(reference) == 'table', 'claim reference must be a table')
    assert(index._references[reference] ~= nil,
        'claim reference is forged')
    local claim_id = Internals.claim_id(reference.claim_id,
        'claim reference.claim_id')
    assert(reference.service_run_id == index._service_run_id,
        'claim reference belongs to a foreign service run')
    local claim = index._claims[claim_id]
    assert(claim ~= nil, 'claim reference is forged or stale')
    assert(reference.transaction_id == claim.transaction_id,
        'claim reference does not match its transaction')
    return claim
end

---Returns the derived identity for one provisional plan entry.
---@param invocation_id string
---@param operation_key string|nil
---@param claim_key string
---@return string
function Internals.provisional_identity(invocation_id, operation_key, claim_key)
    return table.concat({'provisional', invocation_id, operation_key or '',
        claim_key}, ':')
end

---Rejects fields outside the exact inert claim-plan contract.
---@param entry table
---@param label string
function Internals.plan_entry_shape(entry, label)
    local allowed = {
        claim_key=true,
        resource_kind=true,
        resource_identity=true,
        exclusive=true,
        provisional=true,
        depends_on_claim_keys=true,
        depends_on_references=true,
        shares_with_references=true,
        consumes_references=true,
    }
    for name in pairs(entry) do
        assert(allowed[name], label .. ' contains an unsupported field')
    end
end

---Normalizes and validates one inert plan entry.
---@param index dwarfspec.ResourceDependencyIndex
---@param entry any
---@param invocation_id string
---@param operation_key string|nil
---@param label string
---@return table
function Internals.plan_entry(index, entry, invocation_id, operation_key, label)
    assert(type(entry) == 'table', label .. ' must be a table')
    Internals.plan_entry_shape(entry, label)
    local normalized = {
        claim_key=Internals.string(entry.claim_key, label .. '.claim_key'),
        resource_kind=Internals.string(entry.resource_kind, label .. '.resource_kind'),
        exclusive=entry.exclusive == true,
        provisional=entry.provisional == true,
        depends_on_claim_keys=Internals.array(entry.depends_on_claim_keys,
            label .. '.depends_on_claim_keys'),
        depends_on_references=Internals.array(entry.depends_on_references,
            label .. '.depends_on_references'),
        shares_with_references=Internals.array(entry.shares_with_references,
            label .. '.shares_with_references'),
        consumes_references=Internals.array(entry.consumes_references,
            label .. '.consumes_references'),
    }
    if normalized.provisional then
        assert(entry.resource_identity == nil,
            label .. ' provisional entry cannot supply resource_identity')
        normalized.resource_identity = Internals.provisional_identity(
            invocation_id, operation_key, normalized.claim_key)
    else
        normalized.resource_identity = Internals.string(entry.resource_identity,
            label .. '.resource_identity')
    end
    return normalized
end

---Rejects fields outside the exact post-effect registration contract.
---@param registration table
---@param label string
function Internals.registration_shape(registration, label)
    local allowed = {
        claim_key=true,
        resource_kind=true,
        resource_identity=true,
        exclusive=true,
        depends_on_claim_keys=true,
        depends_on_references=true,
        shares_with_references=true,
        consumes_references=true,
    }
    for name in pairs(registration) do
        assert(allowed[name],
            label .. ' contains an unsupported field')
    end
end

---Validates local and active relationships for a complete normalized set.
---@param index dwarfspec.ResourceDependencyIndex
---@param owner table
---@param lifetime string
---@param entries table[]
function Internals.relationships(index, owner, lifetime, entries, authorization)
    local keyed = {}
    for _, entry in ipairs(entries) do
        assert(not keyed[entry.claim_key], 'duplicate claim_key in claim plan')
        keyed[entry.claim_key] = entry
    end
    for _, entry in ipairs(entries) do
        local local_seen = {}
        for _, key in ipairs(entry.depends_on_claim_keys) do
            Internals.string(key, 'depends_on_claim_keys entry')
            assert(keyed[key] ~= nil and key ~= entry.claim_key,
                'local dependency must name another claim_key in the plan')
            assert(not local_seen[key], 'duplicate local dependency key')
            local_seen[key] = true
        end
        local reference_seen = {}
        for _, reference in ipairs(entry.depends_on_references) do
            local claim = Internals.reference(index, reference)
            assert(not reference_seen[claim.claim_id], 'duplicate active dependency')
            reference_seen[claim.claim_id] = true
            assert(Internals.owner_contains(claim.owner, owner) and
                Internals.lifetime_depth(owner, lifetime) >=
                    Internals.lifetime_depth(claim.owner, claim.lifetime),
                'dependent claim has an invalid owner or lifetime direction')
        end
        for _, reference in ipairs(entry.shares_with_references) do
            local claim = Internals.reference(index, reference)
            assert(not entry.exclusive and not claim.exclusive,
                'compatible sharing requires explicit nonexclusive claims')
            assert(claim.resource_kind == entry.resource_kind and
                claim.resource_identity == entry.resource_identity,
                'compatible sharing reference has incompatible resource identity')
        end
        for _, reference in ipairs(entry.consumes_references) do
            local claim = Internals.reference(index, reference)
            assert(Internals.owner_key(claim.owner) == Internals.owner_key(owner) or
                authorization == true,
                'consumption requires the exact owning scope or authorization')
            assert(Internals.owner_contains(claim.owner, owner),
                'authorized consumption requires a nested owner')
            assert(Internals.lifetime_depth(owner, lifetime) >=
                Internals.lifetime_depth(claim.owner, claim.lifetime),
                'consumption has an invalid lifetime direction')
        end
    end
end

---Rejects exclusive collisions unless the candidate explicitly shares the claim.
---@param index dwarfspec.ResourceDependencyIndex
---@param entries table[]
function Internals.conflicts(index, entries)
    for left_index, left in ipairs(entries) do
        local shared_ids = {}
        for _, reference in ipairs(left.shares_with_references) do
            shared_ids[reference.claim_id] = true
        end
        for claim_id, active in pairs(index._claims) do
            if active.resource_kind == left.resource_kind and
                    active.resource_identity == left.resource_identity then
                assert(not active.exclusive and not left.exclusive and
                    shared_ids[claim_id],
                    'resource claim requires explicit compatible sharing')
            end
        end
        for right_index = left_index + 1, #entries do
            local right = entries[right_index]
            assert(not (left.resource_kind == right.resource_kind and
                left.resource_identity == right.resource_identity),
                'resource claim plan cannot imply local sharing or conflict')
        end
    end
end

---Builds a graph that includes existing claims and prospective claim IDs.
---@param index dwarfspec.ResourceDependencyIndex
---@param entries table[]
---@return dwarfspec.DirectedAcyclicGraph, table<string, string>
function Internals.simulated_graph(index, entries)
    local graph = DirectedAcyclicGraph.new()
    for claim_id in pairs(index._claims) do graph:add_node(claim_id) end
    local prospective = {}
    for ordinal, entry in ipairs(entries) do
        local id = '__prospective__:' .. tostring(ordinal)
        graph:add_node(id)
        prospective[entry.claim_key] = id
    end
    for claim_id, claim in pairs(index._claims) do
        for _, dependent_id in ipairs(index._graph:successors(claim_id)) do
            graph:add_edge(claim_id, dependent_id)
        end
    end
    for _, entry in ipairs(entries) do
        local dependent_id = prospective[entry.claim_key]
        for _, key in ipairs(entry.depends_on_claim_keys) do
            graph:add_edge(prospective[key], dependent_id)
        end
        for _, reference in ipairs(entry.depends_on_references) do
            graph:add_edge(reference.claim_id, dependent_id)
        end
        for _, reference in ipairs(entry.consumes_references) do
            graph:add_edge(reference.claim_id, dependent_id)
        end
    end
    return graph, prospective
end

---Creates a run-scoped resource policy index.
---@param service_run_id string
---@param release_authorizer? fun(transaction_id: string, proof: any): string
---@return dwarfspec.ResourceDependencyIndex
function ResourceDependencyIndex.new(service_run_id, release_authorizer)
    assert(release_authorizer == nil or type(release_authorizer) == 'function',
        'release_authorizer must be callable when supplied')
    return setmetatable({
        _service_run_id=Internals.string(service_run_id, 'service_run_id'),
        _graph=DirectedAcyclicGraph.new(),
        _claims={},
        _transaction_claim_ids={},
        _plans=setmetatable({}, {__mode='k'}),
        _references=setmetatable({}, {__mode='k'}),
        _conflicted_records={},
        _consumption_authorizations=setmetatable({}, {__mode='k'}),
        _release_authorizer=release_authorizer,
        _next_claim_ordinal=0,
    }, ResourceDependencyIndex)
end

---Validates and freezes an inert plan without changing ownership state.
---@param owner dwarfspec.ExecutionOwnerIdentity
---@param invocation_id string
---@param lifetime dwarfspec.ECleanupLifetime
---@param entries dwarfspec.ResourceClaimPlanEntry[]
---@param operation_key? string
---@return table validated_plan
function ResourceDependencyIndex:validate_plan(owner, invocation_id, lifetime,
        entries, operation_key, consumption_authorization)
    owner = Internals.owner(owner, self._service_run_id)
    invocation_id = Internals.string(invocation_id, 'invocation_id')
    assert(lifetime == CleanupLifetime.COMMAND or lifetime == CleanupLifetime.OWNER,
        'lifetime has unsupported value')
    if operation_key ~= nil then Internals.string(operation_key, 'operation_key') end
    entries = Internals.array(entries, 'claim plan entries')
    local normalized = {}
    for ordinal, entry in ipairs(entries) do
        normalized[ordinal] = Internals.plan_entry(self, entry, invocation_id,
            operation_key, ('claim plan entry %d'):format(ordinal))
    end
    local authorized = consumption_authorization ~= nil and
        self._consumption_authorizations[consumption_authorization] == true
    assert(consumption_authorization == nil or authorized,
        'consumption authorization is invalid')
    Internals.relationships(self, owner, lifetime, normalized, authorized)
    Internals.conflicts(self, normalized)
    Internals.simulated_graph(self, normalized)
    local plan = Internals.freeze({owner=owner, invocation_id=invocation_id,
        lifetime=lifetime, operation_key=operation_key,
        consumption_authorized=authorized, entries=normalized})
    self._plans[plan] = true
    return plan
end

---Creates a narrow authorization from a validated explicit command policy.
---@param definition dwarfspec.CommandDefinition
---@return table
function ResourceDependencyIndex:consumption_authorization(definition)
    assert(Definition.is_validated(definition) and definition.cleanup and
        definition.cleanup.allow_cross_owner_consumption == true,
        'definition does not authorize cross-owner consumption')
    local authorization = Internals.freeze({})
    self._consumption_authorizations[authorization] = true
    return authorization
end

---Activates a validated subset atomically for a registered transaction.
---@param plan table
---@param transaction_id string
---@param bindings dwarfspec.ResourceClaimBinding[]
---@return dwarfspec.ResourceClaimReference[]
function ResourceDependencyIndex:activate(plan, transaction_id, bindings)
    assert(self._plans[plan] == true,
        'plan must be a validated resource claim plan')
    transaction_id = Internals.string(transaction_id, 'transaction_id')
    assert(self._transaction_claim_ids[transaction_id] == nil,
        'transaction already owns resource claims')
    bindings = Internals.array(bindings, 'claim bindings')
    local by_key, selected = {}, {}
    for _, entry in ipairs(plan.entries) do by_key[entry.claim_key] = entry end
    for ordinal, binding in ipairs(bindings) do
        assert(type(binding) == 'table', 'claim binding must be a table')
        for name in pairs(binding) do
            assert(name == 'claim_key' or name == 'resource_identity',
                'binding cannot introduce claim policy or relationships')
        end
        local key = Internals.string(binding.claim_key,
            ('claim binding %d.claim_key'):format(ordinal))
        local entry = by_key[key]
        assert(entry ~= nil and not selected[key], 'binding names unknown or duplicate claim_key')
        local identity = binding.resource_identity
        if entry.provisional then
            identity = Internals.string(identity, 'provisional binding.resource_identity')
        else
            assert(identity == nil or identity == entry.resource_identity,
                'binding changed exact existing resource identity')
            identity = entry.resource_identity
        end
        local copy = {}
        for name, value in pairs(entry) do copy[name] = value end
        copy.resource_identity = identity
        selected[key] = copy
    end
    local activated = {}
    for _, entry in pairs(selected) do table.insert(activated, entry) end
    table.sort(activated, function(left, right) return left.claim_key < right.claim_key end)
    Internals.relationships(self, plan.owner, plan.lifetime, activated,
        plan.consumption_authorized)
    Internals.conflicts(self, activated)
    Internals.simulated_graph(self, activated)
    for _, entry in ipairs(activated) do
        for _, key in ipairs(entry.depends_on_claim_keys) do
            assert(selected[key] ~= nil,
                'activated claim omitted a local prerequisite')
        end
    end
    if #activated == 0 then return Internals.freeze({}) end
    local transaction_claim_ids = {}
    local references = {}
    for _, entry in ipairs(activated) do
        self._next_claim_ordinal = self._next_claim_ordinal + 1
        local claim_id = table.concat({self._service_run_id, 'claim',
            tostring(self._next_claim_ordinal)}, ':')
        self._graph:add_node(claim_id)
        local claim = Internals.freeze({claim_id=claim_id,
            transaction_id=transaction_id, service_run_id=self._service_run_id,
            owner=plan.owner, lifetime=plan.lifetime,
            resource_kind=entry.resource_kind,
            resource_identity=entry.resource_identity, exclusive=entry.exclusive})
        self._claims[claim_id] = claim
        transaction_claim_ids[claim_id] = true
        local reference = Internals.freeze({claim_id=claim_id,
            transaction_id=transaction_id, service_run_id=self._service_run_id})
        Internals.reference_tokens[reference] = true
        self._references[reference] = claim_id
        references[#references + 1] = reference
        selected[entry.claim_key]._claim_id = claim_id
    end
    self._transaction_claim_ids[transaction_id] = transaction_claim_ids
    for _, entry in ipairs(activated) do
        for _, key in ipairs(entry.depends_on_claim_keys) do
            local prerequisite = selected[key]
            assert(prerequisite ~= nil, 'activated claim omitted a local prerequisite')
            self._graph:add_edge(prerequisite._claim_id, entry._claim_id)
        end
        for _, reference in ipairs(entry.depends_on_references) do
            self._graph:add_edge(reference.claim_id, entry._claim_id)
        end
        for _, reference in ipairs(entry.consumes_references) do
            self._graph:add_edge(reference.claim_id, entry._claim_id)
        end
    end
    return Internals.freeze(references)
end

---Registers exact post-effect claims atomically with a transaction identity.
---@param owner dwarfspec.ExecutionOwnerIdentity
---@param transaction_id string
---@param lifetime dwarfspec.ECleanupLifetime
---@param registrations dwarfspec.ResourceClaimRegistration[]
---@return dwarfspec.ResourceClaimReference[]
function ResourceDependencyIndex:register(owner, transaction_id, lifetime, registrations)
    registrations = Internals.array(registrations, 'claim registrations')
    for ordinal, registration in ipairs(registrations) do
        assert(type(registration) == 'table',
            ('claim registration %d must be a table'):format(ordinal))
        Internals.registration_shape(registration,
            ('claim registration %d'):format(ordinal))
    end
    local plan = self:validate_plan(owner, 'post-effect-registration',
        lifetime, registrations)
    local bindings = {}
    for _, entry in ipairs(plan.entries) do
        assert(not entry.provisional,
            'post-effect registration cannot use provisional identity')
        bindings[#bindings + 1] = {claim_key=entry.claim_key}
    end
    return self:activate(plan, transaction_id, bindings)
end

---Returns an immutable active claim snapshot for a valid reference.
---@param reference dwarfspec.ResourceClaimReference
---@return table
function ResourceDependencyIndex:lookup(reference)
    return Internals.reference(self, reference)
end

---Returns immutable references for every currently active claim of a transaction.
---@param transaction_id string
---@return dwarfspec.ResourceClaimReference[]
function ResourceDependencyIndex:references_for_transaction(transaction_id)
    transaction_id = Internals.string(transaction_id, 'transaction_id')
    local references = {}
    for claim_id in pairs(self._transaction_claim_ids[transaction_id] or {}) do
        local claim = self._claims[claim_id]
        local reference = Internals.freeze({claim_id=claim_id,
            transaction_id=claim.transaction_id,
            service_run_id=self._service_run_id})
        Internals.reference_tokens[reference] = true
        self._references[reference] = claim_id
        references[#references + 1] = reference
    end
    table.sort(references, function(left, right) return left.claim_id < right.claim_id end)
    return Internals.freeze(references)
end

---Records fail-closed registration evidence without creating normal claims.
---@param transaction_id string
---@param owner dwarfspec.ExecutionOwnerIdentity
---@param evidence table
---@return table
function ResourceDependencyIndex:record_conflicted_registration(transaction_id,
        owner, evidence)
    transaction_id = Internals.string(transaction_id, 'transaction_id')
    owner = Internals.owner(owner, self._service_run_id)
    assert(type(evidence) == 'table', 'conflict evidence must be a table')
    assert(self._transaction_claim_ids[transaction_id] == nil and
        self._conflicted_records[transaction_id] == nil,
        'transaction already has claim state')
    local sanitized_evidence = Internals.evidence_diagnostics:sanitize(evidence,
        'conflicted registration evidence')
    local record = Internals.freeze({transaction_id=transaction_id,
        service_run_id=self._service_run_id, owner=owner,
        evidence=sanitized_evidence})
    self._conflicted_records[transaction_id] = record
    return record
end

---Retains unresolved claims after failed or unconfirmed cleanup.
---@param transaction_id string
function ResourceDependencyIndex:retain_unresolved(transaction_id)
    transaction_id = Internals.string(transaction_id, 'transaction_id')
    assert(self._transaction_claim_ids[transaction_id] ~= nil,
        'transaction has no active claims to retain')
end

---Explicitly rehomes one active claim to a transaction with a new owner.
---@param reference dwarfspec.ResourceClaimReference
---@param owner dwarfspec.ExecutionOwnerIdentity
---@param transaction_id string
---@return dwarfspec.ResourceClaimReference
function ResourceDependencyIndex:transfer(reference, owner, transaction_id)
    local claim = Internals.reference(self, reference)
    owner = Internals.owner(owner, self._service_run_id)
    transaction_id = Internals.string(transaction_id, 'transaction_id')
    assert(transaction_id ~= claim.transaction_id,
        'transfer requires a different transaction')
    local target_claim_ids = self._transaction_claim_ids[transaction_id]
    assert(target_claim_ids == nil or target_claim_ids[claim.claim_id] == nil,
        'target transaction already owns this claim')
    for _, prerequisite_id in ipairs(self._graph:predecessors(claim.claim_id)) do
        local prerequisite = self._claims[prerequisite_id]
        assert(Internals.owner_contains(prerequisite.owner, owner) and
            Internals.lifetime_depth(owner, claim.lifetime) >=
                Internals.lifetime_depth(prerequisite.owner, prerequisite.lifetime),
            'transfer would create an invalid prerequisite lifetime direction')
    end
    for _, dependent_id in ipairs(self._graph:successors(claim.claim_id)) do
        local dependent = self._claims[dependent_id]
        assert(Internals.owner_contains(owner, dependent.owner) and
            Internals.lifetime_depth(dependent.owner, dependent.lifetime) >=
                Internals.lifetime_depth(owner, claim.lifetime),
            'transfer would create an invalid dependent lifetime direction')
    end
    local replacement = {claim_id=claim.claim_id, transaction_id=transaction_id,
        service_run_id=self._service_run_id, owner=owner, lifetime=claim.lifetime,
        resource_kind=claim.resource_kind, resource_identity=claim.resource_identity,
        exclusive=claim.exclusive}
    self._claims[claim.claim_id] = Internals.freeze(replacement)
    self._transaction_claim_ids[claim.transaction_id][claim.claim_id] = nil
    if next(self._transaction_claim_ids[claim.transaction_id]) == nil then
        self._transaction_claim_ids[claim.transaction_id] = nil
    end
    target_claim_ids = self._transaction_claim_ids[transaction_id] or {}
    target_claim_ids[claim.claim_id] = true
    self._transaction_claim_ids[transaction_id] = target_claim_ids
    local transferred = Internals.freeze({claim_id=claim.claim_id,
        transaction_id=transaction_id, service_run_id=self._service_run_id})
    Internals.reference_tokens[transferred] = true
    self._references[transferred] = claim.claim_id
    return transferred
end

---Releases all transaction claims only when no active dependent remains.
---@param transaction_id string
---@param proof any
function ResourceDependencyIndex:release_verified(transaction_id, proof)
    transaction_id = Internals.string(transaction_id, 'transaction_id')
    local claim_ids = self._transaction_claim_ids[transaction_id]
    assert(claim_ids ~= nil, 'transaction has no active claims to release')
    for claim_id in pairs(claim_ids) do
        assert(#self._graph:successors(claim_id) == 0,
            'cannot release a prerequisite while an active dependent remains')
    end
    assert(self._release_authorizer ~= nil,
        'verified claim release requires transaction authorization')
    local disposition = self._release_authorizer(transaction_id, proof)
    assert(disposition == 'complete' or disposition == 'abandoned',
        'transaction did not authorize a releasable disposition')
    for claim_id in pairs(claim_ids) do
        self._graph:remove_node(claim_id)
        self._claims[claim_id] = nil
    end
    self._transaction_claim_ids[transaction_id] = nil
end

return ResourceDependencyIndex
