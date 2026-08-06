-- Unit contracts for run-scoped effect-backed resource claim policy.

local Lifetime = require('dwarfspec.protocol.enums.cleanup_lifetimes')
local OwnerScope = require('dwarfspec.protocol.enums.execution_owner_scopes')
local ResourceDependencyIndex = require(
    'dwarfspec.driver.command.resource_dependency_index')
local Definition = require('dwarfspec.driver.command.definition')
local CommandKind = require('dwarfspec.protocol.enums.command_kinds')
local IntrinsicKind = require(
    'dwarfspec.protocol.enums.intrinsic_verification_kinds')
local RetryPolicy = require(
    'dwarfspec.protocol.enums.execution_retry_policies')

---@param callback fun()
---@param expected string
local function assert_error(callback, expected)
    local succeeded, message = pcall(callback)
    assert.is_false(succeeded)
    assert.is_truthy(tostring(message):find(expected, 1, true))
end

---@param scope string
---@param suite_id? string
---@param test_id? string
---@return dwarfspec.ExecutionOwnerIdentity
local function owner(scope, suite_id, test_id)
    return {owner_scope=scope, service_run_id='run-1',
        suite_execution_id=suite_id, test_attempt_id=test_id}
end

---@param index dwarfspec.ResourceDependencyIndex
---@param execution_owner dwarfspec.ExecutionOwnerIdentity
---@param entries dwarfspec.ResourceClaimPlanEntry[]
---@return table
local function plan(index, execution_owner, entries)
    return index:validate_plan(execution_owner, 'invocation-1', Lifetime.OWNER,
        entries)
end

---@param claim_key string
---@param identity? string
---@return dwarfspec.ResourceClaimPlanEntry
local function exclusive_claim(claim_key, identity)
    return {claim_key=claim_key, resource_kind='unit',
        resource_identity=identity or 'unit-1', exclusive=true}
end

---Creates an index plus a transaction-owned release-proof issuer.
---@param service_run_id? string
---@return dwarfspec.ResourceDependencyIndex
---@return fun(transaction_id: string, disposition?: string): table
local function releasable_index(service_run_id)
    local authorized = {}
    local index = ResourceDependencyIndex.new(service_run_id or 'run-1',
        function(transaction_id, proof)
            assert(authorized[transaction_id] == proof,
                'release proof was not issued for this transaction')
            return proof.disposition
        end)
    local function authorize(transaction_id, disposition)
        local proof = {disposition=disposition or 'complete'}
        authorized[transaction_id] = proof
        return proof
    end
    return index, authorize
end

describe('ResourceDependencyIndex inert plans', function()
    it('validates a plan without allocating any active reference', function()
        local index = ResourceDependencyIndex.new('run-1')
        local validated = plan(index, owner(OwnerScope.TEST_ATTEMPT, 'suite-1',
            'test-1'), {exclusive_claim('created')})
        assert.same({}, index:references_for_transaction('transaction-1'))
        assert_error(function() index:activate({}, 'transaction-1', {}) end,
            'validated resource claim plan')
        assert_error(function() index:lookup({claim_id='claim'}) end, 'forged')
        assert.are.equal('created', validated.entries[1].claim_key)
        assert_error(function() validated.entries[1].claim_key = 'other' end,
            'immutable')
    end)

    it('normalizes owners to their declared identity fields', function()
        local index = ResourceDependencyIndex.new('run-1')
        local execution_owner = owner(OwnerScope.SERVICE_RUN)
        execution_owner.untrusted = function() end
        local validated = plan(index, execution_owner, {exclusive_claim('claim')})
        assert.is_nil(validated.owner.untrusted)
    end)

    it('derives provisional identities from invocation and retry operation key', function()
        local index = ResourceDependencyIndex.new('run-1')
        local first = index:validate_plan(owner(OwnerScope.TEST_ATTEMPT, 'suite-1',
            'test-1'), 'invocation-1', Lifetime.OWNER,
            {{claim_key='created', resource_kind='unit', exclusive=true,
                provisional=true}}, 'operation-1')
        local second = index:validate_plan(owner(OwnerScope.TEST_ATTEMPT, 'suite-1',
            'test-1'), 'invocation-1', Lifetime.OWNER,
            {{claim_key='created', resource_kind='unit', exclusive=true,
                provisional=true}}, 'operation-2')
        assert.are_not.equal(first.entries[1].resource_identity,
            second.entries[1].resource_identity)
    end)

    it('round-trips maximum bounded correlation components', function()
        local component = string.rep('x', 128)
        local index = ResourceDependencyIndex.new(component)
        local validated = index:validate_plan({owner_scope=OwnerScope.SERVICE_RUN,
            service_run_id=component}, component, Lifetime.OWNER,
            {{claim_key=component, resource_kind=component, exclusive=true,
                provisional=true}}, component)
        local reference = index:activate(validated, component,
            {{claim_key=component, resource_identity=component}})[1]
        assert.are.equal(component, index:lookup(reference).resource_identity)
        local registered = index:register({owner_scope=OwnerScope.SERVICE_RUN,
            service_run_id=component}, string.rep('y', 128), Lifetime.OWNER,
            {{claim_key='other', resource_kind='other',
                resource_identity='other', exclusive=true}})
        assert.are.equal(1, #registered)
    end)

    it('rejects invalid local keys and does not create active state', function()
        local index = ResourceDependencyIndex.new('run-1')
        assert_error(function()
            plan(index, owner(OwnerScope.TEST_ATTEMPT, 'suite-1', 'test-1'), {
                {claim_key='one', resource_kind='unit', resource_identity='1',
                    exclusive=true, depends_on_claim_keys={'missing'}},
            })
        end, 'local dependency')
        assert.same({}, index:references_for_transaction('transaction-1'))
    end)

    it('rejects unsupported inert plan fields', function()
        local index = ResourceDependencyIndex.new('run-1')
        assert_error(function()
            plan(index, owner(OwnerScope.TEST_ATTEMPT, 'suite-1', 'test-1'), {
                {claim_key='one', resource_kind='unit', resource_identity='1',
                    exclusive=true, depends_on_reference={}},
            })
        end, 'unsupported field')
        assert.same({}, index:references_for_transaction('transaction-1'))
    end)
end)

describe('ResourceDependencyIndex activation', function()
    it('activates an explicit subset and binds concrete provisional identity', function()
        local index = ResourceDependencyIndex.new('run-1')
        local validated = plan(index, owner(OwnerScope.TEST_ATTEMPT, 'suite-1',
            'test-1'), {
            {claim_key='created', resource_kind='unit', exclusive=true,
                provisional=true},
            exclusive_claim('unused', 'unit-2'),
        })
        local references = index:activate(validated, 'transaction-1', {
            {claim_key='created', resource_identity='unit-99'},
        })
        assert.are.equal(1, #references)
        assert.are.equal('unit-99', index:lookup(references[1]).resource_identity)
        assert_error(function()
            index:activate(validated, 'transaction-2', {{claim_key='unknown'}})
        end, 'unknown or duplicate')
    end)

    it('leaves no transaction state when an effect binds no planned claim', function()
        local index = ResourceDependencyIndex.new('run-1')
        local validated = plan(index, owner(OwnerScope.TEST_ATTEMPT, 'suite-1',
            'test-1'), {exclusive_claim('optional')})
        assert.same({}, index:activate(validated, 'transaction-1', {}))
        local references = index:activate(validated, 'transaction-1',
            {{claim_key='optional'}})
        assert.are.equal(1, #references)
    end)

    it('rejects forged, foreign, stale, and incompatible references', function()
        local index, authorize = releasable_index()
        local source = plan(index, owner(OwnerScope.SUITE_EXECUTION, 'suite-1'),
            {{claim_key='source', resource_kind='unit', resource_identity='unit-1',
                exclusive=false}})
        local reference = index:activate(source, 'transaction-1',
            {{claim_key='source'}})[1]
        assert_error(function()
            plan(index, owner(OwnerScope.TEST_ATTEMPT, 'suite-1', 'test-1'), {
                {claim_key='dependent', resource_kind='unit',
                    resource_identity='unit-1', exclusive=true,
                    depends_on_references={{claim_id=reference.claim_id,
                        transaction_id=reference.transaction_id,
                        service_run_id='run-2'}}},
            })
        end, 'forged')
        index:release_verified('transaction-1', authorize('transaction-1'))
        assert_error(function() index:lookup(reference) end, 'stale')
    end)

    it('enforces complete-run conflicts and explicit compatible sharing', function()
        local index, authorize = releasable_index()
        local shared = plan(index, owner(OwnerScope.SUITE_EXECUTION, 'suite-1'), {
            {claim_key='shared', resource_kind='unit', resource_identity='unit-1',
                exclusive=false},
        })
        local reference = index:activate(shared, 'transaction-1',
            {{claim_key='shared'}})[1]
        assert_error(function()
            plan(index, owner(OwnerScope.TEST_ATTEMPT, 'suite-1', 'test-1'),
                {exclusive_claim('exclusive')})
        end, 'explicit compatible sharing')
        local compatible = plan(index, owner(OwnerScope.TEST_ATTEMPT, 'suite-1',
            'test-1'), {{claim_key='compatible', resource_kind='unit',
                resource_identity='unit-1', exclusive=false,
                shares_with_references={reference}}})
        assert.are.equal('compatible', compatible.entries[1].claim_key)
        assert_error(function()
            plan(index, owner(OwnerScope.TEST_ATTEMPT, 'suite-1', 'test-2'), {
                {claim_key='implicit', resource_kind='unit',
                    resource_identity='unit-1', exclusive=false},
            })
        end, 'explicit compatible sharing')
    end)

    it('enforces nested lifetime direction and blocks prerequisite release', function()
        local index, authorize = releasable_index()
        local parent = plan(index, owner(OwnerScope.SUITE_EXECUTION, 'suite-1'), {
            exclusive_claim('parent'),
        })
        local parent_reference = index:activate(parent, 'transaction-parent',
            {{claim_key='parent'}})[1]
        local child = plan(index, owner(OwnerScope.TEST_ATTEMPT, 'suite-1',
            'test-1'), {{claim_key='child', resource_kind='other',
                resource_identity='child-1', exclusive=true,
                depends_on_references={parent_reference}}})
        index:activate(child, 'transaction-child', {{claim_key='child'}})
        assert_error(function()
            index:release_verified('transaction-parent',
                authorize('transaction-parent'))
        end,
            'active dependent')
        index:release_verified('transaction-child',
            authorize('transaction-child'))
        index:release_verified('transaction-parent',
            authorize('transaction-parent'))
        assert_error(function() index:lookup(parent_reference) end, 'stale')
    end)

    it('rehomes only through the explicit transfer operation', function()
        local index, authorize = releasable_index()
        local source = plan(index, owner(OwnerScope.SUITE_EXECUTION, 'suite-1'), {
            exclusive_claim('source'),
        })
        local reference = index:activate(source, 'transaction-source',
            {{claim_key='source'}})[1]
        local transferred = index:transfer(reference,
            owner(OwnerScope.TEST_ATTEMPT, 'suite-1', 'test-1'),
            'transaction-target')
        assert.are.equal('transaction-target',
            index:lookup(transferred).transaction_id)
        assert_error(function() index:lookup(reference) end, 'match its transaction')
    end)

    it('requires exact ownership and dependency ordering for consumption', function()
        local index, authorize = releasable_index()
        local source = plan(index, owner(OwnerScope.TEST_ATTEMPT, 'suite-1',
            'test-1'), {exclusive_claim('source')})
        local reference = index:activate(source, 'transaction-source',
            {{claim_key='source'}})[1]
        assert_error(function()
            plan(index, owner(OwnerScope.TEST_ATTEMPT, 'suite-1', 'test-2'), {
                {claim_key='consumer', resource_kind='other',
                    resource_identity='consumer-1', exclusive=true,
                    consumes_references={reference}},
            })
        end, 'exact owning scope')
        local consumer = plan(index, owner(OwnerScope.TEST_ATTEMPT, 'suite-1',
            'test-1'), {{claim_key='consumer', resource_kind='other',
                resource_identity='consumer-1', exclusive=true,
                consumes_references={reference}}})
        index:activate(consumer, 'transaction-consumer',
            {{claim_key='consumer'}})
        assert_error(function()
            index:release_verified('transaction-source',
                authorize('transaction-source'))
        end,
            'active dependent')
    end)

    it('permits nested cross-owner consumption only from validated policy', function()
        local index = ResourceDependencyIndex.new('run-1')
        local source = plan(index, owner(OwnerScope.SUITE_EXECUTION, 'suite-1'),
            {exclusive_claim('source')})
        local reference = index:activate(source, 'transaction-source',
            {{claim_key='source'}})[1]
        local definition = Definition.validate({name='authorized-consumer',
            kind=CommandKind.ACTION, normalize=function(value) return value end,
            preflight=function() end, execute=function() end,
            execution_retry_policy=RetryPolicy.ONCE,
            intrinsic_verification=IntrinsicKind.EXECUTION_RECEIPT,
            cleanup={lifetime=Lifetime.OWNER, restore=function() end,
                verify=function() return true end,
                allow_cross_owner_consumption=true}})
        local authorization = index:consumption_authorization(definition)
        local authorized = index:validate_plan(owner(OwnerScope.TEST_ATTEMPT,
            'suite-1', 'test-1'), 'consumer', Lifetime.OWNER,
            {{claim_key='consumer', resource_kind='other',
                resource_identity='consumer-1', exclusive=true,
                consumes_references={reference}}}, nil, authorization)
        assert.are.equal('consumer', authorized.entries[1].claim_key)
        assert_error(function() index:consumption_authorization({}) end,
            'does not authorize')
        assert.is_nil(Definition._validated)
    end)

    it('rejects sibling dependencies and command-to-owner lifetime reversal', function()
        local index = ResourceDependencyIndex.new('run-1')
        local source = index:validate_plan(owner(OwnerScope.TEST_ATTEMPT,
            'suite-1', 'test-1'), 'source', Lifetime.COMMAND,
            {exclusive_claim('source')})
        local reference = index:activate(source, 'transaction-source',
            {{claim_key='source'}})[1]
        assert_error(function()
            plan(index, owner(OwnerScope.TEST_ATTEMPT, 'suite-1', 'test-2'), {
                {claim_key='sibling', resource_kind='other',
                    resource_identity='sibling-1', exclusive=true,
                    depends_on_references={reference}},
            })
        end, 'invalid owner or lifetime direction')
        assert_error(function()
            plan(index, owner(OwnerScope.TEST_ATTEMPT, 'suite-1', 'test-1'), {
                {claim_key='owner-lifetime', resource_kind='other',
                    resource_identity='owner-1', exclusive=true,
                    depends_on_references={reference}},
            })
        end, 'invalid owner or lifetime direction')
    end)

    it('rejects unplanned bindings without partial activation', function()
        local index = ResourceDependencyIndex.new('run-1')
        local validated = plan(index, owner(OwnerScope.TEST_ATTEMPT, 'suite-1',
            'test-1'), {exclusive_claim('planned')})
        assert_error(function()
            index:activate(validated, 'transaction-1', {{claim_key='unplanned'}})
        end, 'unknown or duplicate')
        assert.same({}, index:references_for_transaction('transaction-1'))
    end)

    it('requires a known transaction and transaction-owned release proof', function()
        local index, authorize = releasable_index()
        local validated = plan(index, owner(OwnerScope.SERVICE_RUN),
            {exclusive_claim('claim')})
        index:activate(validated, 'transaction-1', {{claim_key='claim'}})
        assert_error(function()
            index:release_verified('missing', authorize('missing'))
        end, 'no active claims')
        assert_error(function()
            index:release_verified('transaction-1', {})
        end, 'not issued')
        index:release_verified('transaction-1',
            authorize('transaction-1', 'abandoned'))
    end)
end)

describe('ResourceDependencyIndex post-effect registration', function()
    it('registers exact claims and rejects provisional caller registrations', function()
        local index = ResourceDependencyIndex.new('run-1')
        local references = index:register(owner(OwnerScope.SERVICE_RUN),
            'transaction-1', Lifetime.OWNER, {exclusive_claim('registered')})
        assert.are.equal(1, #references)
        assert_error(function()
            index:register(owner(OwnerScope.SERVICE_RUN), 'transaction-2',
                Lifetime.OWNER, {{claim_key='bad', resource_kind='unit',
                    exclusive=true, provisional=true}})
        end, 'unsupported field')
    end)

    it('rejects unsupported post-effect descriptor fields', function()
        local index = ResourceDependencyIndex.new('run-1')
        assert_error(function()
            index:register(owner(OwnerScope.SERVICE_RUN), 'transaction-1',
                Lifetime.OWNER, {{claim_key='claim', resource_kind='unit',
                    resource_identity='unit-1', exclusive=true,
                    depends_on_reference={}}})
        end, 'unsupported field')
        assert.same({}, index:references_for_transaction('transaction-1'))
    end)

    it('retains unresolved and conflicted state without treating it as active claims', function()
        local index = ResourceDependencyIndex.new('run-1')
        local references = index:register(owner(OwnerScope.SERVICE_RUN),
            'transaction-1', Lifetime.OWNER, {exclusive_claim('registered')})
        index:retain_unresolved('transaction-1')
        assert.are.equal(1, #index:references_for_transaction('transaction-1'))
        local record = index:record_conflicted_registration('transaction-2',
            owner(OwnerScope.SERVICE_RUN), {reason='exclusive conflict'})
        assert.are.equal('transaction-2', record.transaction_id)
        assert.same({}, index:references_for_transaction('transaction-2'))
        assert.is_truthy(index:lookup(references[1]))
    end)

    it('rejects binding policy injection and bounds claim and evidence data', function()
        local index = ResourceDependencyIndex.new('run-1')
        local validated = plan(index, owner(OwnerScope.SERVICE_RUN),
            {exclusive_claim('planned')})
        assert_error(function()
            index:activate(validated, 'transaction-1', {{claim_key='planned',
                depends_on_references={}}})
        end, 'cannot introduce')
        assert_error(function()
            plan(index, owner(OwnerScope.SERVICE_RUN), {{claim_key='x',
                resource_kind=string.rep('k', 513), resource_identity='id',
                exclusive=true}})
        end, 'bounded')
        assert_error(function()
            index:record_conflicted_registration('transaction-2',
                owner(OwnerScope.SERVICE_RUN), {callback=function() end})
        end, 'plain')
    end)
end)
