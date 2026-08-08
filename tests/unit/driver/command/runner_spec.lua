-- Deterministic lifecycle tests for the common verified command runner.

local CommandKind = require('dwarfspec.protocol.enums.command_kinds')
local IntrinsicKind = require(
    'dwarfspec.protocol.enums.intrinsic_verification_kinds')
local Registry = require('dwarfspec.driver.command.registry')
local Runner = require('dwarfspec.driver.command.runner')

---Creates complete inert context dependencies around a controlled fake clock.
---@return table, table
local function dependencies()
    local state = {now=0, checkpoints=0}
    local result = {
        now_ms=function() return state.now end,
        wait=function() state.now = state.now + 1 end,
        cancellation=function() return false, nil end,
        owner=function()
            return {owner_scope='test_attempt', service_run_id='run',
                suite_execution_id='suite', test_attempt_id='attempt'}
        end,
        cleanup_checkpoint=function()
            state.checkpoints = state.checkpoints + 1
            return state.checkpoints
        end,
        new_cancellation=function() return function() return false end end,
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
        remaining_ms=function() return 1 end,
    }
    return result, state
end

---Creates one runner with no-op ownership services for no-effect commands.
---@param registry dwarfspec.CommandRegistry
---@param injected table
---@return dwarfspec.CommandRunner
local function runner(registry, injected, cleanup_service, resource_index)
    return Runner.new({registry=registry, default_timeout_ms=10,
        dependencies=injected, resource_index=resource_index or {
            validate_plan=function() return {} end},
        cleanup_service=cleanup_service or {begin_mutation=function()
            return {release=function() end}
        end, quarantineAmbiguousEffect=function() end}})
end

describe('common command runner', function()
    it('normalizes synchronously and returns an execution receipt result unchanged',
            function()
        local registry = Registry.new()
        registry:register_builtin({name='set', kind=CommandKind.ACTION,
            normalize=function(arguments) return {value=arguments.value} end,
            preflight=function() return require('dwarfspec.driver.command.outcomes')
                .ready(true) end,
            execute=function(_, request)
                return require('dwarfspec.driver.command.outcomes')
                    .executed(request.value, {acknowledged=true})
            end, execution_retry_policy='once',
            intrinsic_verification=IntrinsicKind.EXECUTION_RECEIPT})
        local injected, state = dependencies()
        assert.equals('value', runner(registry, injected):invoke('set',
            {value='value'}))
        assert.equals(2, state.checkpoints)
    end)

    it('uses one deadline while retrying read-only preflight observations',
            function()
        local registry, polls = Registry.new(), 0
        registry:register_builtin({name='query', kind=CommandKind.QUERY,
            normalize=function() return {} end,
            preflight=function()
                polls = polls + 1
                if polls == 1 then return require('dwarfspec.driver.command.outcomes')
                    .pending('not ready') end
                return require('dwarfspec.driver.command.outcomes').ready(true)
            end,
            execute=function() return require('dwarfspec.driver.command.outcomes')
                .ready(nil) end,
            execution_retry_policy='once',
            intrinsic_verification=IntrinsicKind.PRIMARY_OBSERVATION})
        local injected, state = dependencies()
        assert.is_nil(runner(registry, injected):invoke('query', {}))
        assert.equals(3, polls)
        assert.equals(1, state.now)
    end)

    it('finalizes command-lifetime cleanup after intrinsic success', function()
        local registry, cleanup_calls, lease_active = Registry.new(), 0, false
        registry:register_builtin({name='temporary', kind=CommandKind.ACTION,
            normalize=function() return {} end,
            preflight=function() return require('dwarfspec.driver.command.outcomes')
                .ready(true) end,
            execute=function() return require('dwarfspec.driver.command.outcomes')
                .executed('done', {confirmed=true}, {resource='temporary'}) end,
            cleanup={lifetime='command', restore=function() end,
                verify=function() return true end},
            execution_retry_policy='once',
            intrinsic_verification=IntrinsicKind.EXECUTION_RECEIPT})
        local injected = dependencies()
        local cleanup_service = {begin_mutation=function()
            assert.is_false(lease_active)
            lease_active = true
            return {release=function()
                assert.is_true(lease_active)
                lease_active = false
            end}
        end, register=function()
            assert.is_true(lease_active)
            return {isPending=function() return true end,
                execute=function()
                    cleanup_calls = cleanup_calls + 1
                    return true
                end}
        end}
        assert.equals('done', runner(registry, injected, cleanup_service)
            :invoke('temporary', {}))
        assert.equals(1, cleanup_calls)
        assert.is_false(lease_active)
    end)

    it('preserves pending primary observations separately from a nil result',
            function()
        local registry, observations = Registry.new(), 0
        registry:register_builtin({name='find', kind=CommandKind.QUERY,
            normalize=function() return {} end,
            preflight=function() return require('dwarfspec.driver.command.outcomes')
                .ready({target_identity='target-1'}) end,
            execute=function()
                observations = observations + 1
                if observations == 1 then
                    return require('dwarfspec.driver.command.outcomes')
                        .pending('render has not settled')
                end
                return require('dwarfspec.driver.command.outcomes').ready(nil)
            end, execution_retry_policy='once',
            intrinsic_verification=IntrinsicKind.PRIMARY_OBSERVATION})
        local injected, state = dependencies()
        assert.is_nil(runner(registry, injected):invoke('find', {}))
        assert.equals(2, observations)
        assert.equals(1, state.now)
    end)

    it('rejects an explicit retry result from a once-only mutation', function()
        local registry, executions = Registry.new(), 0
        registry:register_builtin({name='once', kind=CommandKind.ACTION,
            normalize=function() return {} end,
            preflight=function() return require('dwarfspec.driver.command.outcomes')
                .ready(true) end,
            execute=function()
                executions = executions + 1
                return require('dwarfspec.driver.command.outcomes')
                    .retry('retry is not permitted')
            end, execution_retry_policy='once',
            intrinsic_verification=IntrinsicKind.EXECUTION_RECEIPT})
        local injected = dependencies()
        assert.has_error(function()
            runner(registry, injected):invoke('once', {})
        end)
        assert.equals(1, executions)
    end)

    it('runs caller verification after intrinsic success without replacing the result',
            function()
        local registry, verifications = Registry.new(), 0
        registry:register_builtin({name='verified', kind=CommandKind.ACTION,
            normalize=function() return {} end,
            preflight=function() return require('dwarfspec.driver.command.outcomes')
                .ready({target_identity='target-1'}) end,
            execute=function() return require('dwarfspec.driver.command.outcomes')
                .executed('public result', {receipt='private'}) end,
            execution_retry_policy='once',
            intrinsic_verification=IntrinsicKind.EXECUTION_RECEIPT})
        local injected, state = dependencies()
        assert.equals('public result', runner(registry, injected):invoke(
            'verified', {}, {verify=function(observation)
                verifications = verifications + 1
                assert.equals('verified', observation.name)
                assert.equals('public result', observation.public_result)
                assert.equals('target-1', observation.stable_target_identity)
                if verifications == 1 then error('assertion is not ready') end
                return true
            end}))
        assert.equals(2, verifications)
        assert.equals(1, state.now)
    end)

    it('derives the retry-safe operation key before claim-plan validation',
            function()
        local registry, received_key = Registry.new(), nil
        registry:register_builtin({name='retryable', kind=CommandKind.ACTION,
            normalize=function() return {subject='stable'} end,
            operation_key=function(request) return 'key:' .. request.subject end,
            preflight=function() return require('dwarfspec.driver.command.outcomes')
                .ready(true) end,
            execute=function() return require('dwarfspec.driver.command.outcomes')
                .retry('not completed') end,
            execution_retry_policy='explicit_retry_safe',
            intrinsic_verification=IntrinsicKind.EXECUTION_RECEIPT})
        local injected = dependencies()
        local index = {validate_plan=function(_, _, _, _, _, key)
            received_key = key
            return {}
        end}
        assert.has_error(function()
            runner(registry, injected, nil, index):invoke('retryable', {})
        end)
        assert.equals('key:stable', received_key)
    end)

    it('runs command-lifetime cleanup when intrinsic verification fails',
            function()
        local registry, cleanup_calls = Registry.new(), 0
        registry:register_builtin({name='unconfirmed', kind=CommandKind.ACTION,
            normalize=function() return {} end,
            preflight=function() return require('dwarfspec.driver.command.outcomes')
                .ready(true) end,
            execute=function() return require('dwarfspec.driver.command.outcomes')
                .executed('private', {receipt='value'}, {resource='temporary'}) end,
            verify=function() return require('dwarfspec.driver.command.outcomes')
                .fatal('effect was not confirmed') end,
            cleanup={lifetime='command', restore=function() end,
                verify=function() return true end}, execution_retry_policy='once',
            intrinsic_verification=IntrinsicKind.CALLBACK})
        local injected = dependencies()
        local cleanup_service = {begin_mutation=function()
            return {release=function() end}
        end, register=function()
            return {isPending=function() return true end,
                execute=function() cleanup_calls = cleanup_calls + 1 end}
        end}
        assert.has_error(function()
            runner(registry, injected, cleanup_service):invoke('unconfirmed', {})
        end)
        assert.equals(1, cleanup_calls)
    end)

    it('publishes one start and terminal event around a completed lifecycle',
            function()
        local registry, events = Registry.new(), {}
        registry:register_builtin({name='evented', kind=CommandKind.ACTION,
            normalize=function() return {} end,
            preflight=function() return require('dwarfspec.driver.command.outcomes')
                .ready(true) end,
            execute=function() return require('dwarfspec.driver.command.outcomes')
                .executed('done', {receipt='value'}) end,
            execution_retry_policy='once',
            intrinsic_verification=IntrinsicKind.EXECUTION_RECEIPT})
        local injected = dependencies()
        injected.publish=function(event_type, payload)
            events[#events + 1] = {event_type=event_type, payload=payload}
        end
        assert.equals('done', runner(registry, injected):invoke('evented',
            {option='value'}))
        assert.same({'command.started', 'command.finished'}, {
            events[1].event_type, events[2].event_type})
        assert.equals('success', events[2].payload.status)
    end)

    it('publishes one failed terminal event after an execution failure',
            function()
        local registry, events = Registry.new(), {}
        registry:register_builtin({name='broken', kind=CommandKind.ACTION,
            normalize=function() return {} end,
            preflight=function() return require('dwarfspec.driver.command.outcomes')
                .ready(true) end,
            execute=function() error('adapter failed') end,
            execution_retry_policy='once',
            intrinsic_verification=IntrinsicKind.EXECUTION_RECEIPT})
        local injected = dependencies()
        injected.publish=function(event_type, payload)
            events[#events + 1] = {event_type=event_type, payload=payload}
        end
        assert.has_error(function() runner(registry, injected):invoke('broken', {}) end)
        assert.same({'command.started', 'command.finished'}, {
            events[1].event_type, events[2].event_type})
        assert.equals('failure', events[2].payload.status)
    end)

    it('expires preflight without executing primary behavior', function()
        local registry, executions = Registry.new(), 0
        registry:register_builtin({name='blocked', kind=CommandKind.QUERY,
            normalize=function() return {} end,
            preflight=function() return require('dwarfspec.driver.command.outcomes')
                .pending('target is not ready') end,
            execute=function() executions = executions + 1 end,
            execution_retry_policy='once',
            intrinsic_verification=IntrinsicKind.PRIMARY_OBSERVATION})
        local injected = dependencies()
        local succeeded, message = pcall(function()
            runner(registry, injected):invoke('blocked', {}, {timeout_ms=2})
        end)
        assert.is_false(succeeded)
        assert.is_truthy(message:find('last pending: target is not ready',
            1, true))
        assert.equals(0, executions)
    end)

    it('honors cancellation before preflight callbacks', function()
        local registry, preflights = Registry.new(), 0
        registry:register_builtin({name='cancelled', kind=CommandKind.QUERY,
            normalize=function() return {} end,
            preflight=function()
                preflights = preflights + 1
                return require('dwarfspec.driver.command.outcomes').ready(true)
            end, execute=function() return require('dwarfspec.driver.command.outcomes')
                .ready(true) end, execution_retry_policy='once',
            intrinsic_verification=IntrinsicKind.PRIMARY_OBSERVATION})
        local injected = dependencies()
        injected.cancellation=function() return true, 'cancel requested' end
        assert.has_error(function()
            runner(registry, injected):invoke('cancelled', {})
        end)
        assert.equals(0, preflights)
    end)

    it('rejects unsupported trailing invocation options before normalization',
            function()
        local registry, normalizations = Registry.new(), 0
        registry:register_builtin({name='options', kind=CommandKind.QUERY,
            normalize=function()
                normalizations = normalizations + 1
                return {}
            end, preflight=function()
                return require('dwarfspec.driver.command.outcomes').ready(true)
            end, execute=function() return require('dwarfspec.driver.command.outcomes')
                .ready(true) end, execution_retry_policy='once',
            intrinsic_verification=IntrinsicKind.PRIMARY_OBSERVATION})
        assert.has_error(function()
            runner(registry, dependencies()):invoke('options', {}, {unknown=true})
        end)
        assert.equals(0, normalizations)
    end)

    it('abandons a registered self-rolled-back effect before failing', function()
        local registry, abandoned = Registry.new(), nil
        registry:register_builtin({name='rolled-back', kind=CommandKind.ACTION,
            normalize=function() return {} end,
            preflight=function() return require('dwarfspec.driver.command.outcomes')
                .ready(true) end,
            execute=function() return require('dwarfspec.driver.command.outcomes')
                .executed('private', {receipt='value'}, {resource='temporary'}) end,
            verify=function() return require('dwarfspec.driver.command.outcomes')
                .effect_absent('effect self-rolled back', {
                    absent_resources={{resource_kind='test',
                        resource_identity='temporary'}}}) end,
            cleanup={lifetime='owner', restore=function() end,
                verify=function() return true end}, execution_retry_policy='once',
            intrinsic_verification=IntrinsicKind.CALLBACK})
        local injected = dependencies()
        local cleanup_service = {begin_mutation=function()
            return {release=function() end}
        end, register=function()
            return {transaction_id=function() return 'transaction-1' end,
                isPending=function() return false end}
        end, abandonSelfRolledBack=function(_, transaction_id, _, proof)
            abandoned = {transaction_id=transaction_id, proof=proof}
        end}
        assert.has_error(function()
            runner(registry, injected, cleanup_service):invoke('rolled-back', {})
        end)
        assert.equals('transaction-1', abandoned.transaction_id)
        assert.equals('effect self-rolled back', abandoned.proof.message)
    end)

    it('composes primary and command-lifetime cleanup failures', function()
        local registry = Registry.new()
        registry:register_builtin({name='partial', kind=CommandKind.ACTION,
            normalize=function() return {} end,
            preflight=function() return require('dwarfspec.driver.command.outcomes')
                .ready(true) end,
            execute=function() return require('dwarfspec.driver.command.outcomes')
                .failed('primary failed', {resource='temporary'}) end,
            cleanup={lifetime='command', restore=function() end,
                verify=function() return true end}, execution_retry_policy='once',
            intrinsic_verification=IntrinsicKind.EXECUTION_RECEIPT})
        local cleanup_service = {begin_mutation=function()
            return {release=function() end}
        end, register=function()
            return {isPending=function() return true end,
                execute=function() error('cleanup failed') end}
        end}
        local succeeded, message = pcall(function()
            runner(registry, dependencies(), cleanup_service):invoke('partial', {})
        end)
        assert.is_false(succeeded)
        assert.is_truthy(message:find('primary failed', 1, true))
        assert.is_truthy(message:find('command cleanup:', 1, true))
        assert.is_truthy(message:find('cleanup failed', 1, true))
    end)

    it('does not drain owner-lifetime cleanup at command completion', function()
        local registry, executions = Registry.new(), 0
        registry:register_builtin({name='retained', kind=CommandKind.ACTION,
            normalize=function() return {} end,
            preflight=function() return require('dwarfspec.driver.command.outcomes')
                .ready(true) end,
            execute=function() return require('dwarfspec.driver.command.outcomes')
                .executed('done', {receipt='value'}, {resource='retained'}) end,
            cleanup={lifetime='owner', restore=function() end,
                verify=function() return true end}, execution_retry_policy='once',
            intrinsic_verification=IntrinsicKind.EXECUTION_RECEIPT})
        local cleanup_service = {begin_mutation=function()
            return {release=function() end}
        end, register=function()
            return {isPending=function() return true end,
                execute=function() executions = executions + 1 end}
        end}
        assert.equals('done', runner(registry, dependencies(), cleanup_service)
            :invoke('retained', {}))
        assert.equals(0, executions)
    end)

    it('rejects forged runtime gates with exact preflight attribution', function()
        local registry, events = Registry.new(), {}
        registry:register_builtin({name='forged-gate', kind=CommandKind.QUERY,
            normalize=function() return {} end,
            preflight=function() return {kind='ready', value=true} end,
            execute=function() return require('dwarfspec.driver.command.outcomes')
                .ready(true) end, execution_retry_policy='once',
            intrinsic_verification=IntrinsicKind.PRIMARY_OBSERVATION})
        local injected = dependencies()
        injected.publish=function(event_type, payload)
            events[#events + 1] = {event_type=event_type, payload=payload}
        end
        local succeeded, message = pcall(function()
            runner(registry, injected):invoke('forged-gate', {})
        end)
        assert.is_false(succeeded)
        assert.is_truthy(message:find('outcome constructor', 1, true))
        assert.equals('preflight', events[2].payload.stage)
    end)

    it('requires an immutable execution receipt for receipt verification',
            function()
        local registry, events = Registry.new(), {}
        registry:register_builtin({name='missing-receipt', kind=CommandKind.ACTION,
            normalize=function() return {} end,
            preflight=function() return require('dwarfspec.driver.command.outcomes')
                .ready(true) end,
            execute=function() return require('dwarfspec.driver.command.outcomes')
                .executed('value') end, execution_retry_policy='once',
            intrinsic_verification=IntrinsicKind.EXECUTION_RECEIPT})
        local injected = dependencies()
        injected.publish=function(event_type, payload)
            events[#events + 1] = {event_type=event_type, payload=payload}
        end
        local succeeded, message = pcall(function()
            runner(registry, injected):invoke('missing-receipt', {})
        end)
        assert.is_false(succeeded)
        assert.is_truthy(message:find('immutable receipt', 1, true))
        assert.equals('execution', events[2].payload.stage)
    end)

    it('runs command cleanup from finally after unexpected intrinsic failure',
            function()
        local registry, cleanup_calls = Registry.new(), 0
        registry:register_builtin({name='finally-cleanup', kind=CommandKind.ACTION,
            normalize=function() return {} end,
            preflight=function() return require('dwarfspec.driver.command.outcomes')
                .ready(true) end,
            execute=function() return require('dwarfspec.driver.command.outcomes')
                .executed('value', {receipt=true}, {resource='temporary'}) end,
            verify=function() return {kind='ready', value=true} end,
            cleanup={lifetime='command', restore=function() end,
                verify=function() return true end}, execution_retry_policy='once',
            intrinsic_verification=IntrinsicKind.CALLBACK})
        local cleanup_service = {begin_mutation=function()
            return {release=function() end}
        end, register=function()
            return {isPending=function() return true end,
                execute=function() cleanup_calls = cleanup_calls + 1 end}
        end}
        local succeeded, message = pcall(function()
            runner(registry, dependencies(), cleanup_service)
                :invoke('finally-cleanup', {})
        end)
        assert.is_false(succeeded)
        assert.equals(1, cleanup_calls)
        assert.is_truthy(message:find('intrinsic_verification:', 1, true))
    end)

    it('quarantines a thrown mutating adapter with an ambiguous effect', function()
        local registry, quarantine = Registry.new(), nil
        registry:register_builtin({name='ambiguous', kind=CommandKind.ACTION,
            normalize=function() return {} end,
            preflight=function() return require('dwarfspec.driver.command.outcomes')
                .ready(true) end,
            execute=function() error('adapter disconnected') end,
            execution_retry_policy='once',
            intrinsic_verification=IntrinsicKind.EXECUTION_RECEIPT})
        local cleanup_service = {begin_mutation=function()
            return {release=function() end}
        end, quarantineAmbiguousEffect=function(_, invocation_id, owner, evidence)
            quarantine = {invocation_id=invocation_id, owner=owner,
                evidence=evidence}
        end}
        assert.has_error(function()
            runner(registry, dependencies(), cleanup_service):invoke('ambiguous', {})
        end)
        assert.is_not_nil(quarantine)
        assert.equals('execution', quarantine.evidence.stage)
        assert.is_truthy(quarantine.evidence.failure:find(
            'adapter disconnected', 1, true))
    end)

    it('quarantines a malformed mutating adapter result', function()
        local registry, quarantine = Registry.new(), nil
        registry:register_builtin({name='malformed', kind=CommandKind.ACTION,
            normalize=function() return {} end,
            preflight=function() return require('dwarfspec.driver.command.outcomes')
                .ready(true) end,
            execute=function() return {kind='executed', public_result='forged'} end,
            execution_retry_policy='once',
            intrinsic_verification=IntrinsicKind.EXECUTION_RECEIPT})
        local cleanup_service = {begin_mutation=function()
            return {release=function() end}
        end, quarantineAmbiguousEffect=function(_, _, _, evidence)
            quarantine = evidence
        end}
        assert.has_error(function()
            runner(registry, dependencies(), cleanup_service)
                :invoke('malformed', {})
        end)
        assert.equals('execution', quarantine.stage)
        assert.is_truthy(quarantine.failure:find('outcome constructor', 1, true))
    end)

    it('refreshes retained subjects after cleanup and before terminal success',
            function()
        local registry, calls = Registry.new(), {}
        registry:register_builtin({name='refresh', kind=CommandKind.ACTION,
            normalize=function() return {} end,
            preflight=function() return require('dwarfspec.driver.command.outcomes')
                .ready(true) end,
            execute=function() return require('dwarfspec.driver.command.outcomes')
                .executed('value', {receipt=true}, {resource='temporary'}) end,
            cleanup={lifetime='command', restore=function() end,
                verify=function() return true end}, execution_retry_policy='once',
            intrinsic_verification=IntrinsicKind.EXECUTION_RECEIPT})
        local injected = dependencies()
        injected.publish=function(event_type)
            if event_type == 'command.finished' then calls[#calls + 1] = 'finish' end
        end
        local cleanup_service = {begin_mutation=function()
            return {release=function() end}
        end, register=function()
            return {isPending=function() return true end,
                execute=function() calls[#calls + 1] = 'cleanup' end}
        end}
        local command_runner = runner(registry, injected, cleanup_service)
        command_runner:setRefreshRetainedSubjects(function()
            calls[#calls + 1] = 'refresh'
        end)
        assert.equals('value', command_runner:invoke('refresh', {}))
        assert.same({'cleanup', 'refresh', 'finish'}, calls)
    end)

    it('attributes retained-subject refresh failure before terminal publication',
            function()
        local registry, terminal = Registry.new(), nil
        registry:register_builtin({name='refresh-failure', kind=CommandKind.ACTION,
            normalize=function() return {} end,
            preflight=function() return require('dwarfspec.driver.command.outcomes')
                .ready(true) end,
            execute=function() return require('dwarfspec.driver.command.outcomes')
                .executed('value', {receipt=true}) end,
            execution_retry_policy='once',
            intrinsic_verification=IntrinsicKind.EXECUTION_RECEIPT})
        local injected = dependencies()
        injected.publish=function(event_type, payload)
            if event_type == 'command.finished' then terminal = payload end
        end
        local command_runner = runner(registry, injected)
        command_runner:setRefreshRetainedSubjects(function()
            error('refresh failed')
        end)
        local succeeded, message = pcall(function()
            command_runner:invoke('refresh-failure', {})
        end)
        assert.is_false(succeeded)
        assert.is_truthy(message:find('retained_subject_refresh:', 1, true))
        assert.equals('failure', terminal.status)
        assert.equals('retained_subject_refresh', terminal.stage)
    end)
end)
