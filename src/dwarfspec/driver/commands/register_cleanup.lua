-- Privileged verified command definition for caller-owned post-effect cleanup.

local CommandKind = require('dwarfspec.protocol.enums.command_kinds')
local IntrinsicKind = require(
    'dwarfspec.protocol.enums.intrinsic_verification_kinds')
local RetryPolicy = require(
    'dwarfspec.protocol.enums.execution_retry_policies')
local OwnerScope = require(
    'dwarfspec.protocol.enums.execution_owner_scopes')
local Outcomes = require('dwarfspec.driver.command.outcomes')
local Diagnostics = require('dwarfspec.driver.command.diagnostics')
local Immutable = require('dwarfspec.support.immutable')

---@class dwarfspec.RegisterCleanupCommandFactory
local RegisterCleanup = {}

---@class dwarfspec.driver.commands.RegisterCleanupInternals
local Internals = {}
Internals.diagnostics = Diagnostics.new()

---Copies an execution owner from one command identity.
---@param identity table
---@return dwarfspec.ExecutionOwnerIdentity
function Internals.owner(identity)
    return Immutable.freeze({owner_scope=identity.owner_scope,
        service_run_id=identity.service_run_id,
        suite_execution_id=identity.suite_execution_id,
        test_attempt_id=identity.test_attempt_id}, 'cleanup owner')
end

---Validates and snapshots one public cleanup registration.
---@param registration any
---@param freeze_registrations fun(value: table|nil): table
---@return table
function Internals.registration(registration, freeze_registrations)
    assert(type(registration) == 'table',
        'cleanup registration must be a table')
    local allowed = {label=true, receipt=true, resource_claims=true,
        restore=true, verify=true, cleanup_timeout_ms=true}
    for field in pairs(registration) do
        assert(allowed[field],
            'cleanup registration contains unsupported field ' ..
            tostring(field))
    end
    assert(type(registration.label) == 'string' and
        registration.label ~= '' and #registration.label <= 128,
        'cleanup registration label must be bounded and nonempty')
    local receipt_type = type(registration.receipt)
    assert(receipt_type == 'boolean' or receipt_type == 'number' or
        receipt_type == 'string' or receipt_type == 'table',
        'cleanup registration receipt must be bounded plain data')
    assert(type(registration.restore) == 'function',
        'cleanup registration restore must be callable')
    assert(type(registration.verify) == 'function',
        'cleanup registration verification must be callable')
    if registration.cleanup_timeout_ms ~= nil then
        assert(type(registration.cleanup_timeout_ms) == 'number' and
            registration.cleanup_timeout_ms >= 1 and
            registration.cleanup_timeout_ms % 1 == 0 and
            registration.cleanup_timeout_ms < math.huge,
            'cleanup timeout must be a positive finite integer')
    end
    return Immutable.read_only({label=registration.label,
        receipt=Internals.diagnostics:sanitize(registration.receipt,
            'cleanup receipt'), restore=registration.restore,
        verify=registration.verify,
        cleanup_timeout_ms=registration.cleanup_timeout_ms,
        resource_claims=freeze_registrations(registration.resource_claims)},
        'cleanup registration')
end

---Creates the built-in definition using run-scoped cleanup authorities.
---@param options table
---@return dwarfspec.CommandDefinition
function RegisterCleanup.new(options)
    assert(type(options) == 'table',
        'registerCleanup command options are required')
    assert(type(options.freeze_registrations) == 'function',
        'registerCleanup requires claim registration validation')
    assert(type(options.assert_registration_open) == 'function',
        'registerCleanup requires owner lifecycle validation')
    assert(type(options.verify_registration) == 'function',
        'registerCleanup requires semantic registration verification')
    assert(type(options.wrap_handle) == 'function',
        'registerCleanup requires a public handle factory')
    return {
        name='registerCleanup', kind=CommandKind.ACTION,
        privileged_cleanup_registration=true,
        normalize=function(arguments)
            assert(type(arguments) == 'table',
                'registerCleanup arguments must be a table')
            return Internals.registration(arguments.registration,
                options.freeze_registrations)
        end,
        preflight=function(context)
            local owner = Internals.owner(context:identity())
            assert(owner.owner_scope == OwnerScope.SUITE_EXECUTION or
                owner.owner_scope == OwnerScope.TEST_ATTEMPT,
                'registerCleanup requires an active suite or test owner')
            options.assert_registration_open(owner)
            return Outcomes.ready(owner)
        end,
        claims=function() return {} end,
        execute=function(context, request, owner)
            local transaction = context:cleanup_registration():register({
                label=request.label, receipt=request.receipt,
                restore=request.restore, verify=request.verify,
                cleanup_timeout_ms=request.cleanup_timeout_ms,
                registrations=request.resource_claims,
            })
            local receipt = {transaction_id=transaction:transaction_id()}
            return Outcomes.executed(
                options.wrap_handle(transaction, owner), receipt)
        end,
        execution_retry_policy=RetryPolicy.ONCE,
        intrinsic_verification=IntrinsicKind.CALLBACK,
        verify=function(context, _, receipt)
            options.verify_registration(receipt.transaction_id,
                Internals.owner(context:identity()))
            return Outcomes.ready(true, {
                transaction_id=receipt.transaction_id,
                registration_confirmed=true,
            })
        end,
    }
end

return RegisterCleanup
