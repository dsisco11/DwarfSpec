-- Unit contracts for the privileged receipt-backed cleanup command.

local RegisterCleanup = require('dwarfspec.driver.builtins.register_cleanup')
local CleanupRegistrationService = require(
    'dwarfspec.driver.cleanup.cleanup_registration_service')
local CleanupTransactionHandle = require(
    'dwarfspec.driver.cleanup.cleanup_transaction_handle')
local Registry = require('dwarfspec.driver.command.registry')
local ResourceDependencyIndex = require(
    'dwarfspec.driver.command.resource_dependency_index')
local Runner = require('dwarfspec.driver.command.runner')
local CommandKind = require('dwarfspec.protocol.enums.command_kinds')
local IntrinsicKind = require(
    'dwarfspec.protocol.enums.intrinsic_verification_kinds')
local RetryPolicy = require(
    'dwarfspec.protocol.enums.execution_retry_policies')
local Outcomes = require('dwarfspec.driver.command.outcomes')

---@return table
local function identity()
    return {owner_scope='test_attempt', service_run_id='run',
        suite_execution_id='suite', test_attempt_id='attempt',
        repeat_index=1, spec_file_identity='synthetic_spec.lua',
        test_identity='synthetic test'}
end

---@param owner table
---@param capability? table
---@return table
local function context(owner, capability)
    return {
        identity=function() return owner end,
        cleanup_registration=function() return capability end,
    }
end

---@param current_owner table
---@return table
local function dependencies(current_owner)
    return {
        now_ms=function() return 0 end,
        wait=function() end,
        cancellation=function() return false, nil end,
        owner=function() return current_owner end,
        cleanup_checkpoint=function() return 0 end,
        new_cancellation=function()
            return function() return false, nil end
        end,
        invoke_readonly=function() end,
        record_diagnostic=function() end,
        assert_cleanup_executable=function() end,
        resolve_mount=function() end,
        resolve_target=function() end,
        lookup_claim=function() end,
        capture_render=function() end,
        observe_render=function() end,
        wait_frames=function() end,
        wait_ticks=function() end,
        wait_event=function() end,
        wait_until=function() end,
        execute_step=function() end,
        remaining_ms=function() return 10 end,
    }
end

describe('registerCleanup command definition', function()
    it('freezes registration data while retaining cleanup callbacks', function()
        local restored = function() end
        local verified = function() return true end
        local registrations = {{claim_key='unit'}}
        local definition = RegisterCleanup.new({
            freeze_registrations=function(value)
                assert.equals(registrations, value)
                return {{claim_key='frozen'}}
            end,
            assert_registration_open=function() end,
            verify_registration=function() end,
            wrap_handle=function() end,
        }):definition()

        local request = definition.normalize({registration={label='restore unit',
            receipt={unit_id=7}, resource_claims=registrations,
            restore=restored, verify=verified, cleanup_timeout_ms=20}})

        assert.equals(restored, request.restore)
        assert.equals(verified, request.verify)
        assert.equals(7, request.receipt.unit_id)
        assert.equals('frozen', request.resource_claims[1].claim_key)
        assert.has_error(function() request.label = 'changed' end,
            'cleanup registration is immutable')
        assert.has_error(function() request.receipt.unit_id = 8 end,
            'cleanup receipt is immutable')
    end)

    it('registers once, returns a handle, and verifies transaction identity',
            function()
        local expected_owner = identity()
        local registered
        local verified
        local transaction = {transaction_id=function() return 'tx-1' end}
        local handle = {public=true}
        local definition = RegisterCleanup.new({
            freeze_registrations=function(value) return value or {} end,
            assert_registration_open=function(owner)
                assert.same(expected_owner, owner)
            end,
            verify_registration=function(transaction_id, owner)
                verified = {transaction_id=transaction_id, owner=owner}
            end,
            wrap_handle=function(value, owner)
                assert.equals(transaction, value)
                assert.same(expected_owner, owner)
                return handle
            end,
        }):definition()
        local request = definition.normalize({registration={label='restore',
            receipt={value=1}, restore=function() end,
            verify=function() return true end}})
        local readiness = definition.preflight(context(expected_owner))
        local outcome = definition.execute(context(expected_owner, {
            register=function(_, registration)
                registered = registration
                return transaction
            end,
        }), request, readiness.value)

        assert.equals(handle, outcome.public_result)
        assert.equals('tx-1', outcome.receipt.transaction_id)
        assert.is_nil(outcome.effect_receipt)
        assert.equals('restore', registered.label)
        local result = definition.verify(context(expected_owner), request,
            outcome.receipt)
        assert.equals('tx-1', verified.transaction_id)
        assert.same(expected_owner, verified.owner)
        assert.is_true(result.value)
    end)

    it('rejects malformed registration before any lifecycle effect', function()
        local definition = RegisterCleanup.new({
            freeze_registrations=function(value) return value or {} end,
            assert_registration_open=function() end,
            verify_registration=function() end,
            wrap_handle=function() end,
        }):definition()

        assert.has_error(function()
            definition.normalize({registration={label='missing callbacks',
                receipt={}}})
        end, 'cleanup registration restore must be callable')
        assert.has_error(function()
            definition.normalize({registration={label='bad timeout',
                receipt={}, restore=function() end,
                verify=function() end, cleanup_timeout_ms=0}})
        end, 'cleanup timeout must be a positive finite integer')
    end)

    it('rejects registration without an active suite or test owner', function()
        local definition = RegisterCleanup.new({
            freeze_registrations=function(value) return value or {} end,
            assert_registration_open=function()
                error('service validation must not receive a service owner')
            end,
            verify_registration=function() end,
            wrap_handle=function() end,
        }):definition()
        local service_owner = {owner_scope='service_run',
            service_run_id='run'}

        assert.has_error(function()
            definition.preflight(context(service_owner))
        end, 'registerCleanup requires an active suite or test owner')
    end)

    it('uses the real runner service and owner teardown transaction path',
            function()
        local active_owner = identity()
        local restored = false
        local cleanup_service
        local index = ResourceDependencyIndex.new('run',
            function(transaction_id, proof)
                return cleanup_service:authorizeRelease(transaction_id, proof)
            end)
        cleanup_service = CleanupRegistrationService.new({
            service_run_id='run', resource_index=index,
            now_ms=function() return 0 end,
        })
        local command_runner = Runner.new({registry=Registry.new(),
            resource_index=index, cleanup_service=cleanup_service,
            default_timeout_ms=20,
            dependencies=dependencies(active_owner)})
        command_runner:registerBuiltin(RegisterCleanup.new({
            freeze_registrations=function(value)
                return index:freeze_registrations(value)
            end,
            assert_registration_open=function(owner)
                return cleanup_service:assertRegistrationOpen(owner)
            end,
            verify_registration=function(transaction_id, owner)
                return cleanup_service:verifyRegistration(transaction_id, owner)
            end,
            wrap_handle=function(transaction, owner)
                return CleanupTransactionHandle.new(transaction, owner,
                    function() return active_owner end,
                    function(expected)
                        return command_runner:assertHandleExecution(expected)
                    end)
            end,
        }):definition())

        local handle = command_runner:invoke('registerCleanup', {
            registration={label='restore unit', receipt=7,
                resource_claims={{claim_key='unit', resource_kind='unit',
                    resource_identity='unit-7', exclusive=true}},
                restore=function(_, receipt)
                    assert.equals(7, receipt)
                    restored = true
                end,
                verify=function() return restored end,
            },
        })

        assert.is_true(handle:isPending())
        assert.equals(1, #handle:claimReferences())
        local early_restored = false
        local early = command_runner:invoke('registerCleanup', {
            registration={label='early cleanup', receipt='early',
                restore=function(_, receipt)
                    assert.equals('early', receipt)
                    early_restored = true
                end,
                verify=function() return early_restored end,
            },
        })
        assert.is_true(early:execute('manual cleanup'))
        assert.is_true(early_restored)
        assert.is_false(early:execute('manual cleanup again'))
        command_runner:registerBuiltin({name='nested-handle',
            kind=CommandKind.ACTION,
            normalize=function(arguments) return arguments end,
            preflight=function() return Outcomes.ready(true) end,
            execute=function()
                handle:execute('nested command')
                return Outcomes.executed(true, true)
            end,
            execution_retry_policy=RetryPolicy.ONCE,
            intrinsic_verification=IntrinsicKind.CALLBACK,
            verify=function() return Outcomes.ready(true) end})
        local nested_succeeded, nested_failure = pcall(function()
            command_runner:invoke('nested-handle', {})
        end)
        assert.is_false(nested_succeeded)
        assert.is_truthy(tostring(nested_failure):find(
            'cleanup handle execution is forbidden during command execution',
            1, true))
        assert.is_true(handle:isPending())
        local confirmed = cleanup_service:finalize_owner(active_owner,
            'test teardown')
        assert.is_true(confirmed)
        assert.is_true(restored)
        assert.is_false(handle:isPending())
        local late_succeeded, late_failure = pcall(function()
            command_runner:invoke('registerCleanup', {registration={
                label='late cleanup', receipt=true,
                restore=function() end,
                verify=function() return true end,
            }})
        end)
        assert.is_false(late_succeeded)
        assert.is_truthy(tostring(late_failure):find(
            'cleanup registration is closed for this owner', 1, true))
    end)
end)
